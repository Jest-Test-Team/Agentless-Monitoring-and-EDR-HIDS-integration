#!/bin/bash
# Phase 6: Health Monitoring & Alerting
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_PATH="/etc/agentless/deploy.conf"
if [ -f "$CONF_PATH" ]; then
    source "$CONF_PATH"
elif [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

echo "[*] Phase 6: Health Monitoring Setup"
echo "========================================"

# Comprehensive health check script
cat > /usr/local/bin/healthcheck-all.sh << 'HEALTH'
#!/bin/bash
# Run: healthcheck-all.sh [--alert]
ALERT="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
status=0

check_component() {
    local name="$1" cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} $name"
    else
        echo -e "${RED}[FAIL]${NC} $name"
        status=1
        [ -n "$ALERT" ] && logger -t healthcheck -p local0.err "Healthcheck FAIL: $name"
    fi
}

echo "=== Healthcheck $(date) ==="

# DRAKVUF
for GUEST in $(virsh list --name 2>/dev/null || echo ""); do
    [ -z "$GUEST" ] && continue
    PID=$(pgrep -f "drakvuf.*-r ${GUEST}" | head -1)
    if [ -n "$PID" ]; then
        echo -e "${GREEN}[OK]${NC} DRAKVUF: ${GUEST} (PID: $PID)"
    else
        echo -e "${RED}[FAIL]${NC} DRAKVUF: ${GUEST} (not running)"
        status=1
    fi
done

# Systemd services
for svc in libvirtd suricata filebeat redis* logstash; do
    check_component "Service: $svc" "systemctl is-active --quiet $svc"
done

# Disk
for dir in /var/log/drakvuf /var/log/suricata /var/log/filebeat; do
    if [ -d "$dir" ]; then
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo -e "${GREEN}[OK]${NC} Disk: $dir ($SIZE)"
    fi
done

# Disk usage alerts
ROOT_USAGE=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
if [ "$ROOT_USAGE" -gt 85 ]; then
    echo -e "${RED}[ALERT]${NC} Root disk: ${ROOT_USAGE}% used"
    [ -n "$ALERT" ] && logger -t healthcheck -p local0.warn "Root disk ${ROOT_USAGE}% full"
    status=1
fi

# Log freshness
for GUEST in $(virsh list --name 2>/dev/null || echo ""); do
    [ -z "$GUEST" ] && continue
    JSON_FILE="/var/log/drakvuf/${GUEST}.json"
    if [ -f "$JSON_FILE" ]; then
        AGE=$(( $(date +%s) - $(stat -c %Y "$JSON_FILE") ))
        if [ $AGE -gt 600 ]; then
            echo -e "${YELLOW}[WARN]${NC} Stale log: ${GUEST} (${AGE}s since last write)"
            [ -n "$ALERT" ] && logger -t healthcheck -p local0.warn "Stale DRAKVUF log: ${GUEST} (${AGE}s)"
        else
            echo -e "${GREEN}[OK]${NC} Fresh log: ${GUEST} (${AGE}s ago)"
        fi
    fi
done

# Auditd alerts
ALERTS=$(ausearch -k drakvuf_binary --start recent --format text 2>/dev/null | head -5)
if [ -n "$ALERTS" ]; then
    echo -e "${RED}[ALERT]${NC} DRAKVUF binary audit events detected:"
    echo "$ALERTS"
    status=1
fi

# OpenSearch connectivity
if command -v curl &>/dev/null; then
    for host in 10.0.0.10 10.0.0.11 10.0.0.12; do
        if curl -sf "http://${host}:9200/_cat/health" &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} OpenSearch: ${host}"
            break
        fi
    done
fi

echo "=== Status: $([ $status -eq 0 ] && echo 'HEALTHY' || echo 'DEGRADED') ==="
exit $status
HEALTH
chmod +x /usr/local/bin/healthcheck-all.sh

# Cron: hourly check, daily alert
cat > /etc/cron.d/healthcheck << 'CRON'
# Healthcheck: log every hour, alert on failure every 6 hours
0 * * * * root /usr/local/bin/healthcheck-all.sh | logger -t healthcheck
0 */6 * * * root /usr/local/bin/healthcheck-all.sh --alert
CRON

# OpenSearch ISM policy for log retention (tier-configurable)
mkdir -p /etc/opensearch

# Tier 0: 365 days retention
cat > /etc/opensearch/ism-policy-tier0.json << 'ISM0'
{
  "policy": {
    "policy_id": "security-events-retention-tier0",
    "description": "Tier 0 retention: 365 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [{
          "rollover": { "min_size": "50gb", "min_index_age": "1d" }
        }],
        "transitions": [{ "state_name": "warm", "conditions": { "min_index_age": "7d" } }]
      },
      {
        "name": "warm",
        "actions": [],
        "transitions": [{ "state_name": "delete", "conditions": { "min_index_age": "365d" } }]
      },
      { "name": "delete", "actions": [{ "delete": {} }] }
    ]
  }
}
ISM0

# Tier 1: 90 days retention
cat > /etc/opensearch/ism-policy-tier1.json << 'ISM1'
{
  "policy": {
    "policy_id": "security-events-retention-tier1",
    "description": "Tier 1 retention: 90 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [{
          "rollover": { "min_size": "50gb", "min_index_age": "1d" }
        }],
        "transitions": [{ "state_name": "warm", "conditions": { "min_index_age": "3d" } }]
      },
      {
        "name": "warm",
        "actions": [],
        "transitions": [{ "state_name": "delete", "conditions": { "min_index_age": "90d" } }]
      },
      { "name": "delete", "actions": [{ "delete": {} }] }
    ]
  }
}
ISM1

# Tier 2: 365 days retention (bare metal, high value)
cat > /etc/opensearch/ism-policy-tier2.json << 'ISM2'
{
  "policy": {
    "policy_id": "security-events-retention-tier2",
    "description": "Tier 2 retention: 365 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [{
          "rollover": { "min_size": "50gb", "min_index_age": "1d" }
        }],
        "transitions": [{ "state_name": "warm", "conditions": { "min_index_age": "7d" } }]
      },
      {
        "name": "warm",
        "actions": [],
        "transitions": [{ "state_name": "delete", "conditions": { "min_index_age": "365d" } }]
      },
      { "name": "delete", "actions": [{ "delete": {} }] }
    ]
  }
}
ISM2

# Tier 3: 30 days retention (dev/test)
cat > /etc/opensearch/ism-policy-tier3.json << 'ISM3'
{
  "policy": {
    "policy_id": "security-events-retention-tier3",
    "description": "Tier 3 retention: 30 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [{
          "rollover": { "min_size": "20gb", "min_index_age": "1d" }
        }],
        "transitions": [{ "state_name": "warm", "conditions": { "min_index_age": "1d" } }]
      },
      {
        "name": "warm",
        "actions": [],
        "transitions": [{ "state_name": "delete", "conditions": { "min_index_age": "30d" } }]
      },
      { "name": "delete", "actions": [{ "delete": {} }] }
    ]
  }
}
ISM3

echo "[+] ISM policies generated for all tiers"
echo "    Apply via curl: curl -X PUT 'http://OPENSEARCH_HOST:9200/_plugins/_ism/policies/security-events-retention-tier0' -H 'Content-Type: application/json' -d @/etc/opensearch/ism-policy-tier0.json"

# Loki/Promtail alternative monitoring
cat > /etc/promtail/promtail.yml << 'PROMTAIL' || true
# If using Grafana Loki instead of ELK for infrastructure monitoring
scrape_configs:
- job_name: drakvuf
  static_configs:
  - targets: [localhost]
    labels:
      job: drakvuf
      __path__: /var/log/drakvuf/*.json
PROMTAIL

echo "[+] Health monitoring deployed"
echo "    Manual run: /usr/local/bin/healthcheck-all.sh"
echo "    Logs:       journalctl -t healthcheck"
