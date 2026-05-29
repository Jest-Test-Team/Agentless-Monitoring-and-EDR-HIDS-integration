#!/bin/bash
# Phase 4: Wazuh Agent Deployment (Tier 1/2/3)
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

WAZUH_MANAGER="${1:-${WAZUH_MANAGER:-10.0.0.30}}"
TIER="${2:-tier1}"  # tier1, tier2, tier3

echo "[*] Phase 4: Wazuh Agent Deployment (Tier: $TIER)"
echo "  Manager: $WAZUH_MANAGER"
echo "========================================"

# Install Wazuh agent
if ! rpm -q wazuh-agent &>/dev/null; then
    curl -s https://packages.wazuh.com/4.x/wazuh-install.sh | bash -s -- agent "$WAZUH_MANAGER"
    echo "[+] Wazuh agent installed"
fi

# Tier-specific configuration
case "$TIER" in
    tier1)
        # Tier 1: Wazuh Agent + Osquery + Auditd (internal service VM)
        if ! rpm -q osquery &>/dev/null; then
            dnf install -y osquery
        fi
        cat > /etc/osquery/osquery.conf << 'OSQ'
{
  "schedule": {
    "kernel_modules": {
      "query": "SELECT name, size, used_by, status FROM kernel_modules;",
      "interval": 300
    },
    "listening_ports": {
      "query": "SELECT pid, port, protocol, address FROM listening_ports;",
      "interval": 60
    },
    "process_events": {
      "query": "SELECT pid, path, cmdline, time FROM process_events;",
      "interval": 120
    },
    "suid_binaries": {
      "query": "SELECT path FROM suid_binaries;",
      "interval": 86400
    },
    "crontab": {
      "query": "SELECT * FROM crontab;",
      "interval": 3600
    },
    "authorized_keys": {
      "query": "SELECT * FROM authorized_keys;",
      "interval": 3600
    }
  }
}
OSQ
        systemctl enable --now osquery

        cat > /var/ossec/etc/ossec.conf << 'OSSEC'
<ossec_config>
  <client>
    <server>
      <address>WAZUH_MANAGER</address>
      <port>1514</port>
      <protocol>TCP</protocol>
    </server>
  </client>

  <syscheck>
    <frequency>7200</frequency>
    <directories check_all="yes">/etc,/usr/bin,/usr/sbin,/bin,/sbin</directories>
    <directories check_all="yes" realtime="yes">/etc/ssh</directories>
    <ignore>/etc/mtab</ignore>
  </syscheck>

  <rootcheck>
    <frequency>3600</frequency>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>

  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>
</ossec_config>
OSSEC
        sed -i "s/WAZUH_MANAGER/$WAZUH_MANAGER/" /var/ossec/etc/ossec.conf
        ;;

    tier2)
        # Bare metal: full monitoring
        dnf install -y osquery

        cat > /etc/osquery/osquery.conf << 'OSQ'
{
  "schedule": {
    "kernel_modules": {
      "query": "SELECT name, size, used_by, status FROM kernel_modules;",
      "interval": 300
    },
    "listening_ports": {
      "query": "SELECT pid, port, protocol, address FROM listening_ports;",
      "interval": 60
    },
    "process_events": {
      "query": "SELECT pid, path, cmdline, time FROM process_events;",
      "interval": 120
    },
    "suid_binaries": {
      "query": "SELECT path FROM suid_binaries;",
      "interval": 86400
    },
    "arp_cache": {
      "query": "SELECT address, mac, interface FROM arp_cache;",
      "interval": 300
    }
  }
}
OSQ
        systemctl enable --now osquery

        cat > /var/ossec/etc/ossec.conf << 'OSSEC2'
<ossec_config>
  <client>
    <server>
      <address>WAZUH_MANAGER</address>
      <port>1514</port>
      <protocol>TCP</protocol>
    </server>
  </client>

  <syscheck>
    <frequency>3600</frequency>
    <directories check_all="yes" realtime="yes">/etc,/usr/bin,/usr/sbin,/bin,/sbin,/root,/home</directories>
  </syscheck>

  <rootcheck>
    <frequency>1800</frequency>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>

  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>

  <localfile>
    <log_format>json</log_format>
    <location>/var/log/osquery/osqueryd.results.log</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>
</ossec_config>
OSSEC2
        sed -i "s/WAZUH_MANAGER/$WAZUH_MANAGER/" /var/ossec/etc/ossec.conf
        ;;

    tier3)
        # Dev/Test: minimal
        cat > /var/ossec/etc/ossec.conf << 'OSSEC3'
<ossec_config>
  <client>
    <server>
      <address>WAZUH_MANAGER</address>
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
        sed -i "s/WAZUH_MANAGER/$WAZUH_MANAGER/" /var/ossec/etc/ossec.conf
        ;;
esac

systemctl enable wazuh-agent
systemctl restart wazuh-agent

echo "[+] Wazuh agent deployed (Tier: $TIER)"
echo "    Verify: /var/ossec/bin/agent_control -l"
