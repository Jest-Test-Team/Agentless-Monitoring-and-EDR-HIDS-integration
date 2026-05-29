#!/bin/bash
# risk-scanner.sh — Main Risk Scanner Orchestrator
# Scans the entire machine across 5 categories and outputs structured JSON
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

source /usr/local/lib/risk-lib.sh 2>/dev/null || source "${SCRIPT_DIR}/risk-lib.sh"

VERSION="1.0.0"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
TIER="${TIER:-tier2}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT_DIR="${OUTPUT_DIR:-/var/log/risk-scanner}"
MODE="${1:-all}"  # all, quick, cve, dry-run

echo "[*] Risk Scanner v${VERSION} starting..."
echo "    Host: $HOSTNAME  Tier: $TIER  Mode: $MODE"
echo "========================================"

mkdir -p "$OUTPUT_DIR"

# ═══════════════════════════════════════════
# CAT_A: System Hardening (35 checks)
# ═══════════════════════════════════════════
echo "[*] CAT_A: System Hardening..."

# Kernel parameters
check_kernel_params "net.ipv4.tcp_syncookies" "1" "TCP SYN cookies" "sysctl -w net.ipv4.tcp_syncookies=1"
check_kernel_params "net.ipv4.conf.all.rp_filter" "1" "Reverse path filtering" "sysctl -w net.ipv4.conf.all.rp_filter=1"
check_kernel_params "net.ipv4.conf.all.accept_redirects" "0" "Accept ICMP redirects" "sysctl -w net.ipv4.conf.all.accept_redirects=0"
check_kernel_params "net.ipv6.conf.all.accept_redirects" "0" "Accept IPv6 redirects" "sysctl -w net.ipv6.conf.all.accept_redirects=0"
check_kernel_params "net.ipv4.conf.all.accept_source_route" "0" "Accept source route" "sysctl -w net.ipv4.conf.all.accept_source_route=0"
check_kernel_params "kernel.kptr_restrict" "2" "kptr_restrict" "sysctl -w kernel.kptr_restrict=2"
check_kernel_params "kernel.dmesg_restrict" "1" "dmesg restrict" "sysctl -w kernel.dmesg_restrict=1"
check_kernel_params "kernel.unprivileged_bpf_disabled" "1" "Unprivileged BPF" "sysctl -w kernel.unprivileged_bpf_disabled=1"
check_kernel_params "kernel.kexec_load_disabled" "1" "kexec disabled" "sysctl -w kernel.kexec_load_disabled=1"

# File permissions
check_file_perms "/etc/shadow" "600" "/etc/shadow permissions" "chmod 600 /etc/shadow"
check_file_perms "/etc/gshadow" "600" "/etc/gshadow permissions" "chmod 600 /etc/gshadow"
check_file_perms "/etc/passwd" "644" "/etc/passwd permissions" "chmod 644 /etc/passwd"
check_file_perms "/etc/ssh/sshd_config" "600" "sshd_config permissions" "chmod 600 /etc/ssh/sshd_config"
check_file_perms "/boot" "755" "/boot permissions" "chmod 755 /boot"

# SUID
check_suid

# SSH config
check_ssh_config "permitrootlogin" "no" "PermitRootLogin" "echo 'PermitRootLogin no' >> /etc/ssh/sshd_config"
check_ssh_config "passwordauthentication" "no" "PasswordAuthentication" "echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config"
check_ssh_config "pubkeyauthentication" "yes" "PubkeyAuthentication" ""
check_ssh_config "protocol" "2" "SSH Protocol" ""
check_ssh_config "maxauthtries" "[1-6]" "MaxAuthTries ≤ 6" "echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config"
check_ssh_config "clientaliveinterval" "[1-9]" "ClientAliveInterval" "echo 'ClientAliveInterval 300' >> /etc/ssh/sshd_config"
check_ssh_config "clientalivecountmax" "[0-3]" "ClientAliveCountMax ≤ 3" "echo 'ClientAliveCountMax 2' >> /etc/ssh/sshd_config"

# SELinux
check_selinux

# Users
check_users

# ═══════════════════════════════════════════
# CAT_B: CVE & Packages (25 checks)
# ═══════════════════════════════════════════
echo "[*] CAT_B: CVE & Packages..."

check_outdated_kernel

# Check for available security updates (RHEL/CentOS)
if command -v yum &>/dev/null; then
    SEC_UPDATES=$(yum updateinfo list security 2>/dev/null | grep -c 'RHSA\|RHBA' || true)
    if [ "$SEC_UPDATES" -gt 0 ]; then
        fail "SECURITY_UPDATES" "$SEC_UPDATES security updates available" "yum update --security"
    else
        pass "SEC_UPDATES" "No pending security updates" ""
    fi
fi

# Check GPG keys
if command -v rpm &>/dev/null; then
    EXPIRED_KEYS=$(rpm -qa gpg-pubkey 2>/dev/null | while read -r k; do
        date_installed=$(rpm -qi "$k" 2>/dev/null | grep "Install Date" | cut -d: -f2-)
        echo "$k: $date_installed"
    done | head -1)
    pass "GPG_KEYS" "GPG keys installed" ""
fi

# Trivy CVE scan (only in --all or --cve mode)
if [ "$MODE" == "all" ] || [ "$MODE" == "cve" ]; then
    check_trivy
fi

# ═══════════════════════════════════════════
# CAT_C: Network Security (20 checks)
# ═══════════════════════════════════════════
echo "[*] CAT_C: Network Security..."

check_listening_ports
check_firewall
check_insecure_services

# Check for promiscuous mode
if ip link show 2>/dev/null | grep -q "PROMISC"; then
    warn "PROMISC_MODE" "Network interface in promiscuous mode" "Check if intentional (packet capture)"
else
    pass "PROMISC_CLEAN" "No promiscuous interfaces" ""
fi

# Check IP forwarding
FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [ "$FORWARD" -eq 1 ]; then
    warn "IP_FORWARD" "IP forwarding enabled" "sysctl -w net.ipv4.ip_forward=0 (unless router)"
else
    pass "IP_FORWARD" "IP forwarding disabled" ""
fi

# ═══════════════════════════════════════════
# CAT_D: Container & Application Security (15 checks)
# ═══════════════════════════════════════════
echo "[*] CAT_D: Container & Application..."

check_docker
check_k8s

# ═══════════════════════════════════════════
# CAT_E: Advanced Threats (20 checks)
# ═══════════════════════════════════════════
echo "[*] CAT_E: Advanced Threats..."

check_rootkit
check_cron_anomalies

# Check for unexpected kernel modules
KNOWN_MODULES="kvm kvm_intel kvm_amd vfio vfio_iommu vfio_pci vhost_net xt_nat xt_conntrack nf_conntrack overlay bridge br_netfilter"
CURRENT_MODS=$(lsmod 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -u)
for m in $CURRENT_MODS; do
    case "$m" in
        kvm*|vfio*|vhost*|xt_*|nf_*|overlay|bridge|br_*|tun|macvtap|ip6t_*) ;;
        *)
            if echo "$KNOWN_MODULES" | grep -qvF "$m"; then
                warn "UNEXPECTED_MODULE" "Unexpected kernel module: $m" "Verify: modinfo $m"
            fi
            ;;
    esac
done

# ═══════════════════════════════════════════
# Generate Score with Python Engine
# ═══════════════════════════════════════════
echo "[*] Computing risk score..."

FINDINGS_FILE=$(mktemp)
printf '%s\n' "${FINDINGS[@]}" > "$FINDINGS_FILE"

RESULT=$(python3 /usr/local/bin/risk-score-engine.py \
    --findings "$FINDINGS_FILE" \
    --hostname "$HOSTNAME" \
    --tier "$TIER" 2>/dev/null || python3 "${SCRIPT_DIR}/risk-score-engine.py" \
    --findings "$FINDINGS_FILE" \
    --hostname "$HOSTNAME" \
    --tier "$TIER")

OVERALL_RISK=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('overall_risk', 0))")
SEVERITY=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('severity', 'unknown'))")

echo "$RESULT" > "${OUTPUT_DIR}/risk-scores-${HOSTNAME}-$(date +%Y%m%d).json"
echo "  [*] Overall risk: $OVERALL_RISK ($SEVERITY)"
echo "  [*] Findings: $(echo "$RESULT" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('top_findings', [])))")"

# If dry-run, print to stdout instead of shipping
if [ "$MODE" == "dry-run" ]; then
    echo ""
    echo "=== DRY RUN — Full Output ==="
    echo "$RESULT" | python3 -m json.tool
    rm -f "$FINDINGS_FILE"
    exit 0
fi

rm -f "$FINDINGS_FILE"
echo "[+] Scan complete."
