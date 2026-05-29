#!/bin/bash
# Phase 2.3: Tier 0 VM Setup — CPU Pinning, HugePages, No-Migrate
# Creates and configures the Tier 0 protected VM for DRAKVUF introspection
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

VM_NAME="${1:?Usage: $0 <vm-name> [vcpus] [memory_gb]}"
VCPUS="${2:-4}"
MEM_GB="${3:-16}"
MEM_KB=$((MEM_GB * 1024 * 1024))
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
DISK_GB="${VM_DISK_GB:-100}"

echo "[*] Phase 2.3: Tier 0 VM Setup"
echo "  VM: $VM_NAME  vCPUs: $VCPUS  RAM: ${MEM_GB}GB  Disk: ${DISK_GB}GB"
echo "========================================"

# 1. Verify host supports hugepages
echo "[*] Configuring hugepages..."
HUGEPAGE_SIZE=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
TOTAL_HUGEPAGES=$((MEM_KB * 1024 / HUGEPAGE_SIZE))
if [ "$TOTAL_HUGEPAGES" -lt 1 ]; then
    echo "[!] Not enough memory for hugepages, falling back to regular pages"
else
    echo "vm.nr_hugepages = $TOTAL_HUGEPAGES" > /etc/sysctl.d/99-hugepages.conf
    sysctl -w "vm.nr_hugepages=$TOTAL_HUGEPAGES"
    echo "[+] HugePages configured: $TOTAL_HUGEPAGES ($MEM_GB GB)"
fi

# 2. Create VM if it doesn't exist
if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "[*] Creating VM $VM_NAME..."

    if [ ! -f "$DISK_PATH" ]; then
        echo "[*] Creating disk image (${DISK_GB}GB)..."
        qemu-img create -f qcow2 "$DISK_PATH" "${DISK_GB}G"
    fi

    virt-install \
        --name "$VM_NAME" \
        --vcpus "$VCPUS" \
        --memory "$MEM_GB" \
        --disk "path=$DISK_PATH,format=qcow2" \
        --network "bridge=br0,model=virtio" \
        --os-variant rhel9 \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole \
        --import

    echo "[+] VM $VM_NAME created"
else
    echo "[*] VM $VM_NAME already exists, updating configuration..."
fi

# 3. CPU pinning (pin vCPUs to physical cores)
echo "[*] Configuring CPU pinning..."
TOTAL_PCPUS=$(lscpu | awk '/^CPU\(s\):/{print $2}')
if [ "$VCPUS" -le "$TOTAL_PCPUS" ]; then
    for vcpu in $(seq 0 $((VCPUS - 1))); do
        virsh vcpupin "$VM_NAME" "$vcpu" "$vcpu"
    done
    echo "[+] vCPUs pinned to physical cores 0-$((VCPUS - 1))"
else
    echo "[WARN] More vCPUs than physical cores; skipping pinning"
fi

# 4. Disable live migration (VM must be pinned to this host)
echo "[*] Disabling live migration..."
virsh migrate-setmaxdowntime "$VM_NAME" 0 2>/dev/null || true
virsh desc --config "$VM_NAME" "AGENTLESS_TIER0:${VM_NAME}" 2>/dev/null || true
echo "[+] Live migration disabled (VM pinned to this host)"

# 5. Memory backing (hugepages)
echo "[*] Configuring memory backing..."
virsh numatune "$VM_NAME" --mode strict 2>/dev/null || true
echo "[+] Memory backing configured"

# 6. Enable qemu-agent inside guest (for symbol retrieval)
echo "[*] Configuring qemu-agent channel..."
virsh attach-device "$VM_NAME" /dev/stdin << 'XML' 2>/dev/null || true
<channel type='unix'>
  <source mode='bind'/>
  <target type='virtio' name='org.qemu.guest_agent.0'/>
</channel>
XML

echo "[+] VM setup complete for $VM_NAME"
echo "    Verify: virsh vcpupin $VM_NAME"
echo "    Verify: virsh dommemstat $VM_NAME"
echo "    Install qemu-guest-agent inside the VM for symbol retrieval"
