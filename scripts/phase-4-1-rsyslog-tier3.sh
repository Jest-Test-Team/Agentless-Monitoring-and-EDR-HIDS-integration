#!/bin/bash
# Phase 4.1: Tier 3 Lightweight Monitoring — Rsyslog Direct to Logstash
# Bypasses Wazuh Manager for dev/test environments
# Ships syslog directly to Logstash for minimal overhead
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
HOSTNAME=$(hostname -s)

echo "[*] Phase 4.1: Tier 3 Rsyslog Direct Shipping"
echo "  Target: ${LOGSTASH_HOST}:${LOGSTASH_PORT}"
echo "  Hostname: $HOSTNAME"
echo "========================================"

# Install rsyslog if not present
if ! rpm -q rsyslog &>/dev/null; then
    dnf install -y rsyslog
fi

# Configure rsyslog to forward all logs to Logstash
cat > /etc/rsyslog.d/90-logstash.conf << 'RSYS'
# Tier 3: Direct log forwarding to Logstash (bypass Wazuh Manager)
# Port 5514 (separate from the Wazuh pipeline on 5044)
template(name="LS_template" type="list") {
    constant(value="<")
    property(name="pri")
    constant(value=">")
    property(name="timestamp" dateFormat="rfc3339")
    constant(value=" ")
    property(name="hostname")
    constant(value=" ")
    property(name="syslogtag" position.from="1" position.to="32")
    constant(value=" ")
    property(name="msg" spifno1stsp="on")
    constant(value="\n")
}

*.* action(
    type="omfwd"
    target="LOGSTASH_HOST_PLACEHOLDER"
    port="LOGSTASH_PORT_PLACEHOLDER"
    protocol="tcp"
    template="LS_template"
    TCP_Framing="octet-counted"
    action.resumeRetryCount="3"
    queue.type="linkedList"
    queue.size="50000"
)
RSYS
sed -i "s/LOGSTASH_HOST_PLACEHOLDER/$LOGSTASH_HOST/" /etc/rsyslog.d/90-logstash.conf
sed -i "s/LOGSTASH_PORT_PLACEHOLDER/$LOGSTASH_PORT/" /etc/rsyslog.d/90-logstash.conf

# Add Logstash input note
echo "[*] Ensure Logstash has a syslog input on port $LOGSTASH_PORT:"
echo "    input { syslog { port => $LOGSTASH_PORT type => \\\"syslog\\\" } }"

systemctl enable rsyslog
systemctl restart rsyslog

# Optional: Install lightweight Wazuh agent (critical alerts only)
if [ "${INSTALL_WAZUH:-no}" = "yes" ]; then
    WAZUH_MANAGER="${WAZUH_MANAGER:-10.0.0.30}"
    curl -s "https://packages.wazuh.com/4.x/wazuh-install.sh" | bash -s -- agent "$WAZUH_MANAGER"

    # Minimal config: only rootcheck + syslog
    cat > /var/ossec/etc/ossec.conf << 'OSSEC3'
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
  </rootcheck>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>
</ossec_config>
OSSEC3
    sed -i "s/WAZUH_MGR/$WAZUH_MANAGER/" /var/ossec/etc/ossec.conf
    systemctl enable wazuh-agent
    systemctl restart wazuh-agent
    echo "[+] Wazuh agent (lightweight) installed"
fi

echo "[+] Tier 3 Rsyslog shipping configured"
echo "    Verify: logger -t test 'Tier3 test message'"
echo "    Check: tail -f /var/log/messages | grep 'omfwd'"
