#!/bin/bash
# Phase 1.3: Dom0 / Tier 0 Host Monitoring
# Installs Wazuh Agent + Osquery + Auditd on the Dom0 host itself
# (Separate from guest VM monitoring — this covers the hypervisor host)
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

WAZUH_MANAGER="${WAZUH_MANAGER:-10.0.0.30}"
HOSTNAME=$(hostname -s)

echo "[*] Phase 1.3: Dom0 Host Monitoring"
echo "  Manager: $WAZUH_MANAGER"
echo "  Hostname: $HOSTNAME"
echo "========================================"

# 1. Install Wazuh Agent
if ! rpm -q wazuh-agent &>/dev/null; then
    echo "[*] Installing Wazuh agent..."
    curl -s "https://packages.wazuh.com/4.x/wazuh-install.sh" | bash -s -- agent "$WAZUH_MANAGER"
    echo "[+] Wazuh agent installed"
fi

# 2. Install Osquery
if ! rpm -q osquery &>/dev/null; then
    echo "[*] Installing osquery..."
    dnf install -y osquery
    echo "[+] Osquery installed"
fi

# 3. Install Auditd
if ! rpm -q audit &>/dev/null; then
    echo "[*] Installing auditd..."
    dnf install -y audit
fi

# 4. Dom0-specific osquery config (focus on hypervisor security)
cat > /etc/osquery/osquery.conf << 'OSQ'
{
  "schedule": {
    "kernel_modules": {
      "query": "SELECT name, size, used_by, status FROM kernel_modules WHERE name LIKE 'kvmi%' OR name LIKE 'kvm%';",
      "interval": 120
    },
    "listening_ports": {
      "query": "SELECT pid, port, protocol, address FROM listening_ports;",
      "interval": 60
    },
    "process_events": {
      "query": "SELECT pid, path, cmdline, time FROM process_events;",
      "interval": 120
    },
    "vm_list": {
      "query": "SELECT name, uuid, state FROM libvirt_domains;",
      "interval": 300,
      "platform": "linux"
    },
    "suid_binaries": {
      "query": "SELECT path FROM suid_binaries;",
      "interval": 86400
    },
    "drakvuf_process": {
      "query": "SELECT pid, name, cmdline FROM processes WHERE name LIKE '%drakvuf%';",
      "interval": 60
    }
  },
  "file_paths": {
    "drakvuf_binaries": ["/usr/local/bin/drakvuf%%"],
    "drakvuf_config": ["/etc/drakvuf/%%"],
    "system_binaries": ["/usr/bin/%%", "/usr/sbin/%%"],
    "etc": ["/etc/%%"]
  }
}
OSQ
systemctl enable --now osquery

# 5. Dom0-specific Auditd rules
cat > /etc/audit/rules.d/dom0-monitoring.rules << 'AUDIT'
# DRAKVUF binary tampering
-w /usr/local/bin/drakvuf -p wa -k drakvuf_binary
-w /etc/drakvuf/ -p wa -k drakvuf_config

# KVMI device access
-w /dev/kvmi -p rwa -k kvmi_device

# Hypervisor management
-w /etc/libvirt/ -p wa -k libvirt_config
-w /var/log/libvirt/ -p wa -k libvirt_log

# Log shipping configuration
-w /etc/filebeat/ -p wa -k filebeat_config

# SSH monitoring
-w /var/log/secure -p wa -k ssh_login
-w /etc/ssh/sshd_config -p wa -k ssh_config

# System critical files
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
-w /etc/sudoers -p wa -k sudoers_change

# Kernel module loading
-w /sbin/insmod -p x -k kernel_module
-w /sbin/modprobe -p x -k kernel_module
AUDIT
augenrules --load
systemctl restart auditd

# 6. Dom0-specific Wazuh agent config
cat > /var/ossec/etc/ossec.conf << 'OSSEC'
<ossec_config>
  <client>
    <server>
      <address>WAZUH_MANAGER_PLACEHOLDER</address>
      <port>1514</port>
      <protocol>TCP</protocol>
    </server>
  </client>

  <syscheck>
    <frequency>3600</frequency>
    <directories check_all="yes" realtime="yes">/etc/drakvuf,/usr/local/bin</directories>
    <directories check_all="yes">/etc,/usr/bin,/usr/sbin,/bin,/sbin,/root</directories>
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
OSSEC
sed -i "s/WAZUH_MANAGER_PLACEHOLDER/$WAZUH_MANAGER/" /var/ossec/etc/ossec.conf
systemctl enable wazuh-agent
systemctl restart wazuh-agent

echo "[+] Dom0 monitoring deployed"
echo "    Components: Wazuh Agent + Osquery + Auditd"
echo "    Verify: /var/ossec/bin/agent_control -l"
echo "    Verify: osqueryi 'SELECT * FROM osquery_info;'"
