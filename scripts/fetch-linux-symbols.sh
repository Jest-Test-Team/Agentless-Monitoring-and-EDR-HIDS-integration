#!/bin/bash
# Utility: Fetch Linux Kernel Symbols from Guest VM
set -euo pipefail

GUEST="${1:?Usage: $0 <guest-name> [kernel-version]}"
KERNEL_VER="${2:-}"
SYMBOL_DIR="/var/lib/drakvuf/symbols/${GUEST}"

echo "[*] Fetching kernel symbols for ${GUEST}..."
mkdir -p "$SYMBOL_DIR"

# Auto-detect kernel version if not provided
if [ -z "$KERNEL_VER" ]; then
    echo "[*] Auto-detecting kernel version via qemu-agent..."
    KERNEL_VER=$(virsh qemu-agent-command "$GUEST" \
        '{"execute":"guest-exec","arguments":{"path":"/usr/bin/uname","arg":["-r"],"capture-output":true}}' 2>/dev/null | \
        python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    exec_id = r.get('return', {}).get('pid', 0)
    print(exec_id)
except: print(0)
" 2>/dev/null || echo "")
fi

# Method 1: Extract system.map from /boot in Guest via qemu-agent
echo "[*] Attempting to read system.map from guest..."
SYS_MAP=$(virsh qemu-agent-command "$GUEST" \
    '{"execute":"guest-exec","arguments":{"path":"/bin/cat","arg":["/boot/System.map-'${KERNEL_VER}'"],"capture-output":true}}' 2>/dev/null || echo "")

# Method 2: Use installed kernel RPM to extract
if [ ! -f "${SYMBOL_DIR}/system.map" ]; then
    echo "[*] Trying to extract system.map from kernel RPM..."
    # This needs to be run inside the guest or on a host with matching RPM
    # For now, create a placeholder with instructions
    cat > "${SYMBOL_DIR}/SYMBOLS_README.txt" << README
To fetch kernel symbols for ${GUEST} (kernel: ${KERNEL_VER}):

Option 1: Inside the guest:
  cp /boot/System.map-${KERNEL_VER} /tmp/system.map
  # Then copy it out via virsh qemu-agent or SCP

Option 2: From the host (if kernel RPM available):
  rpm2cpio kernel-${KERNEL_VER}.rpm | cpio -idm ./boot/System.map-${KERNEL_VER}
  cp boot/System.map-${KERNEL_VER} ${SYMBOL_DIR}/system.map

Option 3: If guest is currently running:
  virsh qemu-agent-command ${GUEST} \
    '{"execute":"guest-file-open","arguments":{"path":"/boot/System.map-${KERNEL_VER}"}}'
  # Then guest-file-read the handle
README
    echo "[!] Could not fetch symbols automatically."
    echo "    See ${SYMBOL_DIR}/SYMBOLS_README.txt for manual steps"
    exit 1
fi

# Verify symbols
echo "[*] Verifying symbols..."
if head -5 "${SYMBOL_DIR}/system.map" | grep -q "T _stext\|D _text"; then
    echo "[+] Symbols look valid"
    echo "    $(wc -l < "${SYMBOL_DIR}/system.map") entries"
else
    echo "[!] WARNING: Symbols may be invalid"
    head -3 "${SYMBOL_DIR}/system.map"
fi

echo "[+] Symbols saved to ${SYMBOL_DIR}/system.map"
