#!/bin/bash
# Phase 4: Wazuh Manager Deployment
# Run this on the Wazuh Manager server (10.0.0.30)
# Covers DEPLOYMENT-RUNBOOK.md 4.1 + 4.3
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

WAZUH_VERSION="${WAZUH_VERSION:-4.9}"
LOGSTASH_HOST="${LOGSTASH_HOSTS%:*}"  # first host, strip port
LOGSTASH_PORT="${LOGSTASH_BEATS_PORT:-5044}"
WAZUH_MANAGER_IP="${WAZUH_MANAGER:-10.0.0.30}"

echo "[*] Phase 4: Wazuh Manager Deployment"
echo "  Version: $WAZUH_VERSION"
echo "  Logstash integration: ${LOGSTASH_HOST}:${LOGSTASH_PORT}"
echo "========================================"

# 4.1: Install Wazuh Manager (central server)
if ! rpm -q wazuh-manager &>/dev/null; then
    echo "[*] Installing Wazuh Manager..."
    curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh"
    bash wazuh-install.sh --wazuh-server
    rm -f wazuh-install.sh
    echo "[+] Wazuh Manager installed"
fi

# 4.3: Configure Logstash integration on Wazuh Manager
# This forwards alerts from Wazuh to the Logstash pipeline
echo "[*] Configuring Wazuh -> Logstash integration..."
INTEGRATION_CONF="/var/ossec/etc/ossec.conf"
if [ -f "$INTEGRATION_CONF" ]; then
    # Check if logstash integration already exists
    if ! grep -q 'logstash' "$INTEGRATION_CONF" 2>/dev/null; then
        cat >> "$INTEGRATION_CONF" << 'CONF'

<ossec_config>
  <integration>
    <name>logstash</name>
    <hook_url>http://LOGSTASH_HOST:LOGSTASH_PORT</hook_url>
    <rule_id>100000,100001</rule_id>
    <alert_format>json</alert_format>
  </integration>
</ossec_config>
CONF
        sed -i "s/LOGSTASH_HOST/${LOGSTASH_HOST}/" "$INTEGRATION_CONF"
        sed -i "s/LOGSTASH_PORT/${LOGSTASH_PORT}/" "$INTEGRATION_CONF"
        systemctl restart wazuh-manager
        echo "[+] Logstash integration configured"
    else
        echo "[*] Logstash integration already exists, skipping"
    fi
fi

# Configure Wazuh cluster (if more than one manager)
if [ -n "${WAZUH_CLUSTER_NODES:-}" ]; then
    echo "[*] Configuring Wazuh cluster..."
    cat > /var/ossec/etc/cluster.yml << 'CLUSTER'
nodes:
  - WAZUH_MANAGER_IP
CLUSTER
    sed -i "s/WAZUH_MANAGER_IP/$WAZUH_MANAGER_IP/" /var/ossec/etc/cluster.yml
    systemctl restart wazuh-manager
    echo "[+] Cluster configured with nodes: $WAZUH_CLUSTER_NODES"
fi

echo "[+] Wazuh Manager deployment complete"
echo "    Verify: systemctl status wazuh-manager"
echo "    Agents: /var/ossec/bin/agent_control -l"
