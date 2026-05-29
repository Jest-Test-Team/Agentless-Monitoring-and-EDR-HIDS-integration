#!/bin/bash
# Phase 0: Hardware & Environment Compatibility Check
# Run this on every potential Tier 0 Host before deployment
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1" result="$2"
    if [ "$result" -eq 0 ]; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASS=$((PASS+1))
    elif [ "$result" -eq 1 ]; then
        echo -e "${RED}[FAIL]${NC} $desc"
        FAIL=$((FAIL+1))
    else
        echo -e "${YELLOW}[WARN]${NC} $desc"
        WARN=$((WARN+1))
    fi
}

echo "============================================"
echo " Phase 0: Compatibility Check"
echo "============================================"
echo ""

# CPU
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}' || echo "unknown")
if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    check "CPU Vendor: Intel" 0
    grep -q 'vmx' /proc/cpuinfo && check "Intel VT-x supported" 0 || check "Intel VT-x supported" 1
    grep -q 'ept' /proc/cpuinfo && check "EPT supported" 0 || check "EPT supported" 1
elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    check "CPU Vendor: AMD (VMI support experimental)" 2
    grep -q 'svm' /proc/cpuinfo && check "AMD SVM supported" 0 || check "AMD SVM supported" 1
else
    check "CPU Vendor: $CPU_VENDOR" 1
fi

# Kernel
KERNEL=$(uname -r)
KVMI_SUPPORTED="5.4 5.10 5.15 6.1"
for ver in $KVMI_SUPPORTED; do
    if echo "$KERNEL" | grep -q "^$ver"; then
        check "Kernel version $KERNEL (KVMI compatible)" 0
        break
    fi
done
check "KVMI kernel patch required (current: $KERNEL)" 2

# KVM module
[ -d /sys/module/kvm ] && check "KVM module loaded" 0 || check "KVM module loaded" 1
[ -d /sys/module/kvm_intel ] && check "KVM-INTEL module loaded" 0
[ -d /sys/module/kvm_amd ] && check "KVM-AMD module loaded" 2

# Altp2m
if [ -f /sys/module/kvm_intel/parameters/altp2m ]; then
    ALTP2M=$(cat /sys/module/kvm_intel/parameters/altp2m)
    [ "$ALTP2M" == "Y" ] && check "Altp2m enabled" 0 || check "Altp2m enabled (run: echo Y > /sys/module/kvm_intel/parameters/altp2m)" 1
fi

# Memory
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
[ "$TOTAL_MEM" -ge 32 ] && check "Memory >= 32GB (found: ${TOTAL_MEM}GB)" 0 || check "Memory >= 32GB (found: ${TOTAL_MEM}GB)" 1

# Disk
ROOT_SPACE=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')
[ "$ROOT_SPACE" -ge 100 ] && check "Root disk >= 100GB (found: ${ROOT_SPACE}GB)" 0 || check "Root disk >= 100GB (found: ${ROOT_SPACE}GB)" 2

# Network interfaces
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" == "lo" ] && continue
    check "Network interface: $name" 0
done

# libvirt
command -v virsh &>/dev/null && check "libvirt installed" 0 || check "libvirt installed" 1

# Build tools
for tool in gcc make cmake git patch; do
    command -v "$tool" &>/dev/null && check "Build tool: $tool" 0 || check "Build tool: $tool" 1
done

echo ""
echo "============================================"
echo -e "${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}  ${YELLOW}Warnings: $WARN${NC}"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    echo "Some checks failed. Review above before proceeding."
    exit 1
fi
exit 0
