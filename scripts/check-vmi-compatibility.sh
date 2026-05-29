#!/bin/bash
# check-vmi-compatibility.sh
# Standalone VMI compatibility checker for Tier 0 deployment
# Referenced by DEPLOYMENT-RUNBOOK.md Phase 0.1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_PATH="/etc/agentless/deploy.conf"
if [ -f "$CONF_PATH" ]; then
    source "$CONF_PATH"
elif [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
COMPATIBLE=1

echo "============================================"
echo " VMI Compatibility Check"
echo "============================================"
echo ""

ok()   { echo -e "${GREEN}[OK]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); COMPATIBLE=0; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }

# 1. CPU vendor
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}' || echo "unknown")
case "$CPU_VENDOR" in
    GenuineIntel)
        ok "CPU: Intel"
        grep -q 'vmx' /proc/cpuinfo && ok "VT-x supported" || fail "VT-x not supported"
        grep -q 'ept' /proc/cpuinfo && ok "EPT supported" || fail "EPT not supported"
        grep -q 'skylake\|arch\|' /proc/cpuinfo | grep -qi 'model' || true
        ;;
    AuthenticAMD)
        warn "CPU: AMD EPYC — KVMI support experimental, Altp2m unavailable"
        warn "This host is NOT suitable for Tier 0 (DRAKVUF VMI). Use Tier 1/2 instead."
        grep -q 'svm' /proc/cpuinfo && ok "SVM supported" || fail "SVM not supported"
        ;;
    *)
        fail "CPU: $CPU_VENDOR (unsupported)"
        ;;
esac

# 2. Altp2m (Intel only)
if [ -f /sys/module/kvm_intel/parameters/altp2m ]; then
    ALTP2M=$(cat /sys/module/kvm_intel/parameters/altp2m)
    if [ "$ALTP2M" = "Y" ]; then
        ok "Altp2m enabled"
    else
        fail "Altp2m disabled — run: echo Y > /sys/module/kvm_intel/parameters/altp2m"
    fi
elif [ -d /sys/module/kvm_amd ]; then
    warn "AMD system: Altp2m unavailable (Intel-only)"
fi

# 3. KVM modules
[ -d /sys/module/kvm ] && ok "KVM module loaded" || fail "KVM module not loaded"
[ -d /sys/module/kvm_intel ] && ok "kvm_intel loaded"
[ -d /sys/module/kvm_amd ] && ok "kvm_amd loaded"

# 4. Kernel version
KERNEL=$(uname -r)
KVMI_VERSIONS="${KVMI_SUPPORTED_KERNELS:-5.4 5.10 5.15 6.1}"
KVMI_OK=0
for ver in $KVMI_VERSIONS; do
    if echo "$KERNEL" | grep -q "^$ver"; then
        ok "Kernel $KERNEL matches KVMI series $ver"
        KVMI_OK=1
        break
    fi
done
[ "$KVMI_OK" -eq 0 ] && warn "Kernel $KERNEL not in KVMI-supported series ($KVMI_VERSIONS)"

# 5. Memory
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
MIN_MEM="${MIN_MEMORY_GB:-32}"
[ "$TOTAL_MEM" -ge "$MIN_MEM" ] && ok "Memory ${TOTAL_MEM}GB >= ${MIN_MEM}GB" \
    || fail "Memory ${TOTAL_MEM}GB < ${MIN_MEM}GB required"

# 6. Disk
ROOT_SPACE=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')
MIN_DISK="${MIN_ROOT_DISK_GB:-100}"
[ "$ROOT_SPACE" -ge "$MIN_DISK" ] && ok "Root disk ${ROOT_SPACE}GB >= ${MIN_DISK}GB" \
    || warn "Root disk ${ROOT_SPACE}GB < ${MIN_DISK}GB"

# 7. libvirt
command -v virsh &>/dev/null && ok "libvirt (virsh) installed" || fail "libvirt not installed"

# 8. Build tools
for tool in gcc make cmake git patch; do
    command -v "$tool" &>/dev/null && ok "Build tool: $tool" || fail "Build tool: $tool missing"
done

echo ""
echo "============================================"
echo -e "${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}  ${YELLOW}Warnings: $WARN${NC}"
echo "============================================"

if [ "$COMPATIBLE" -eq 1 ]; then
    echo "[RESULT] This host is COMPATIBLE for Tier 0 (DRAKVUF VMI)"
    exit 0
else
    echo "[RESULT] This host is NOT compatible for Tier 0"
    echo "  You can still use it for Tier 1/2 monitoring"
    exit 1
fi
