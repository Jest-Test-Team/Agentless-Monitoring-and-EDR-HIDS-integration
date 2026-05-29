#!/bin/bash
# Phase 1.2: Host OS Hardening
# Run on Dom0 / Tier 0 Host after KVMI kernel boot
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

LOGSTASH_PORT="${LOGSTASH_BEATS_PORT:-5044}"
OS_PORT="${OPENSEARCH_API_PORT:-9200}"
WAZUH_AGENT_PORT="${WAZUH_AGENT_PORT:-1514}"
WAZUH_CLUSTER_PORT="${WAZUH_CLUSTER_PORT:-1515}"
REDIS_PORT="${REDIS_PORT:-6379}"

echo "[*] Phase 1.2: Host OS Hardening"
echo "========================================"

# 1. SSH Hardening
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSH'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AuthenticationMethods publickey
LogLevel VERBOSE
SSH

# Generate host keys if missing
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
fi
systemctl restart sshd

# 2. Firewall (Tier 0)
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --zone=trusted --add-source=10.0.0.0/24
    firewall-cmd --permanent --zone=trusted --add-port=22/tcp
    firewall-cmd --permanent --zone=trusted --add-port=16509/tcp
    firewall-cmd --permanent --zone=trusted --add-port=5900-5910/tcp
    firewall-cmd --reload
    echo "[+] Firewall configured"
fi

# 3. SELinux Policy
SELINUX_DIR="/etc/selinux"
mkdir -p "$SELINUX_DIR"
if command -v checkmodule &>/dev/null; then
    TE_FILE="$SELINUX_DIR/drakvuf.te"
    cat > "$TE_FILE" << 'SELINUX'
module drakvuf 1.0;
require {
    type drakvuf_t;
    type virtd_t;
    class process { signal };
    class file { read write };
}
allow drakvuf_t self:process { signal };
allow drakvuf_t virtd_t:file { read write };
SELINUX
    MOD_DIR=$(mktemp -d)
    checkmodule -M -m -o "$MOD_DIR/drakvuf.mod" "$TE_FILE"
    semodule_package -o "$MOD_DIR/drakvuf.pp" -m "$MOD_DIR/drakvuf.mod"
    semodule -i "$MOD_DIR/drakvuf.pp"
    rm -rf "$MOD_DIR"
    echo "[+] SELinux policy loaded from $TE_FILE"
fi

# 4. Auditd Rules
cat > /etc/audit/rules.d/host-hardening.rules << 'AUDIT'
# DRAKVUF monitoring
-w /usr/local/bin/drakvuf -p wa -k drakvuf_binary
-w /etc/drakvuf/ -p wa -k drakvuf_config
-w /dev/kvmi -p rwa -k kvmi_device

# Filebeat
-w /etc/filebeat/ -p wa -k filebeat_config

# SSH
-w /var/log/secure -p wa -k ssh_login
-w /etc/ssh/sshd_config -p wa -k ssh_config

# Critical files
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
-w /etc/sudoers -p wa -k sudoers_change

# Process signals (SIGKILL/SIGTERM to DRAKVUF)
-a exit,always -F arch=b64 -S kill -F pid=1 -k drakvuf_signal

# Kernel module loading
-w /sbin/insmod -p x -k kernel_module
-w /sbin/modprobe -p x -k kernel_module
AUDIT
augenrules --load
systemctl restart auditd
echo "[+] Auditd rules loaded"

# 5. Sysctl hardening
cat > /etc/sysctl.d/99-hardening.conf << 'SYSCTL'
# Network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Kernel hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
kernel.unprivileged_bpf_disabled = 1
kernel.kexec_load_disabled = 1

# OOM
vm.overcommit_memory = 2
vm.overcommit_ratio = 50
SYSCTL
sysctl --system

echo "[*] Host hardening complete. Reboot recommended."
echo "    Verify: auditctl -l | grep drakvuf"
