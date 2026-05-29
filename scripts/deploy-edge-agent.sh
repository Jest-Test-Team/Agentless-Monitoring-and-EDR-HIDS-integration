#!/bin/bash
# deploy-edge-agent.sh — Lightweight agent for edge/terminal/IoT devices
# Supports ARM (Raspberry Pi, SBC), x86 thin clients, and containerized hosts
# Features: minimal disk/memory footprint, rsyslog direct output, offline mode
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

LOGSTASH_HOST="${LOGSTASH_HOSTS%:*}"
LOGSTASH_PORT="${LOGSTASH_TIER3_PORT:-5514}"
WAZUH_MANAGER="${WAZUH_MANAGER:-10.0.0.30}"
ARCH=$(uname -m)
OS=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null || echo "linux")
OFFLINE_MODE="${OFFLINE_MODE:-false}"
OFFLINE_BUNDLE="${OFFLINE_BUNDLE:-}"

echo "[*] Edge Agent Deployment"
echo "  Architecture: $ARCH"
echo "  OS: $OS"
echo "  Logstash: ${LOGSTASH_HOST}:${LOGSTASH_PORT}"
echo "  Offline mode: $OFFLINE_MODE"
echo "========================================"

# Detect if this is a constrained device
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
IS_CONSTRAINED=false
if [ "$TOTAL_MEM" -le 2048 ] || [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "armv7l" ]; then
    IS_CONSTRAINED=true
    echo "[*] Constrained device detected (${TOTAL_MEM}MB RAM, $ARCH)"
fi

# 1. Rsyslog direct shipping (always installed for edge)
echo "[*] Configuring Rsyslog direct shipping..."
if ! rpm -q rsyslog &>/dev/null; then
    if [ "$OFFLINE_MODE" = "true" ] && [ -n "$OFFLINE_BUNDLE" ]; then
        rpm -ivh "$OFFLINE_BUNDLE"/rsyslog*.rpm
    else
        dnf install -y rsyslog
    fi
fi

cat > /etc/rsyslog.d/90-logstash.conf << 'RSYS'
# Edge device: direct log shipping to Logstash
*.* action(
    type="omfwd"
    target="LOGSTASH_HOST_PLACEHOLDER"
    port="LOGSTASH_PORT_PLACEHOLDER"
    protocol="tcp"
    TCP_Framing="octet-counted"
    action.resumeRetryCount="3"
    queue.type="linkedList"
    queue.size="10000"
)
RSYS
sed -i "s/LOGSTASH_HOST_PLACEHOLDER/$LOGSTASH_HOST/" /etc/rsyslog.d/90-logstash.conf
sed -i "s/LOGSTASH_PORT_PLACEHOLDER/$LOGSTASH_PORT/" /etc/rsyslog.d/90-logstash.conf
systemctl enable rsyslog
systemctl restart rsyslog

# 2. Lightweight Wazuh agent (optional, skip for very constrained devices)
if [ "$IS_CONSTRAINED" = false ] || [ "${FORCE_WAZUH:-false}" = "true" ]; then
    echo "[*] Installing lightweight Wazuh agent..."

    if [ "$OFFLINE_MODE" = "true" ] && [ -n "$OFFLINE_BUNDLE" ]; then
        rpm -ivh "$OFFLINE_BUNDLE"/wazuh-agent*.rpm
    else
        curl -s "https://packages.wazuh.com/4.x/wazuh-install.sh" | bash -s -- agent "$WAZUH_MANAGER"
    fi

    # Edge-optimized ossec.conf (rootcheck only, no FIM)
    cat > /var/ossec/etc/ossec.conf << 'EDGE'
<ossec_config>
  <client>
    <server>
      <address>WAZUH_MGR</address>
      <port>1514</port>
      <protocol>TCP</protocol>
    </server>
  </client>
  <rootcheck>
    <frequency>7200</frequency>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>
  <global>
    <memory_limit>256</memory_limit>
  </global>
</ossec_config>
EDGE
    sed -i "s/WAZUH_MGR/$WAZUH_MANAGER/" /var/ossec/etc/ossec.conf

    # Edge performance tuning
    echo "[*] Tuning Wazuh agent for edge..."
    mkdir -p /var/ossec/etc/edge
    cat > /var/ossec/etc/edge/edge.conf << 'TUNE'
# Edge tuning: reduce resource usage
max_eps=50
scan_on_start=false
disable_fim=true
TUNE

    systemctl enable wazuh-agent
    systemctl restart wazuh-agent
    echo "[+] Edge Wazuh agent installed (memory_limit: 256MB)"
else
    echo "[*] Skipping Wazuh agent for constrained device (${TOTAL_MEM}MB RAM)"
    echo "    Use Rsyslog direct shipping only. Set FORCE_WAZUH=true to override."
fi

# 3. Health check (minimal)
cat > /usr/local/bin/edge-healthcheck.sh << 'HEALTH'
#!/bin/bash
echo "=== Edge Healthcheck $(date) ==="
echo "Uptime: $(uptime -p)"
echo "Memory: $(free -m | awk '/^Mem:/{print $3"/"$2"MB"}')"
echo "Disk: $(df -h / | awk 'NR==2{print $3"/"$2}')"
systemctl is-active rsyslog >/dev/null && echo "Rsyslog: OK" || echo "Rsyslog: FAIL"
systemctl is-active wazuh-agent >/dev/null 2>&1 && echo "Wazuh: OK" || echo "Wazuh: not installed"
HEALTH
chmod +x /usr/local/bin/edge-healthcheck.sh

echo "[+] Edge agent deployment complete"
echo "    Architecture: $ARCH"
echo "    Log shipping: ${LOGSTASH_HOST}:${LOGSTASH_PORT}"
echo "    Healthcheck: /usr/local/bin/edge-healthcheck.sh"
