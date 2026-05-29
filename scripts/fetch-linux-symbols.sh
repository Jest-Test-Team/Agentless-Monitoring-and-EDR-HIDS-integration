#!/bin/bash
# Utility: Fetch Linux Kernel Symbols from Guest VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_PATH="/etc/agentless/deploy.conf"
if [ -f "$CONF_PATH" ]; then
    source "$CONF_PATH"
elif [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

GUEST="${1:?Usage: $0 <guest-name> [kernel-version]}"
KERNEL_VER="${2:-}"
SYMBOL_DIR="${DRAKVUF_SYMBOL_DIR:-/var/lib/drakvuf/symbols}/${GUEST}"

echo "[*] Fetching kernel symbols for ${GUEST}..."
mkdir -p "$SYMBOL_DIR"

# Helper: run command in guest via qemu-agent and capture stdout
guest_exec_capture() {
    local guest="$1" cmd="$2"
    shift 2
    local pid
    pid=$(virsh qemu-agent-command "$guest" \
        "$(python3 -c "import json,sys; print(json.dumps({'execute':'guest-exec','arguments':{'path':'$cmd','arg':sys.argv[1:],'capture-output':true}}))" "$@")" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('return',{}).get('pid',0))" 2>/dev/null || echo "0")
    [ "$pid" = "0" ] && return 1
    sleep 1
    local result
    result=$(virsh qemu-agent-command "$guest" \
        "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null || echo '{"return":{"exitcode":-1}}')
    local exitcode
    exitcode=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('return',{}).get('exitcode',-1))" 2>/dev/null || echo "-1")
    if [ "$exitcode" = "0" ]; then
        echo "$result" | python3 -c "import sys,json; import base64; r=json.load(sys.stdin).get('return',{}); print(base64.b64decode(r.get('out-data','')).decode('utf-8','replace'))" 2>/dev/null
        return 0
    fi
    return 1
}

# Auto-detect kernel version if not provided
if [ -z "$KERNEL_VER" ]; then
    echo "[*] Auto-detecting kernel version via qemu-agent..."
    KERNEL_VER=$(guest_exec_capture "$GUEST" /usr/bin/uname -r 2>/dev/null | tr -d '[:space:]') || true
    if [ -n "$KERNEL_VER" ]; then
        echo "[+] Detected kernel: $KERNEL_VER"
    else
        echo "[!] Could not auto-detect kernel version"
    fi
fi

if [ -n "$KERNEL_VER" ]; then
    # Method 1: Extract system.map from /boot in Guest via qemu-agent
    echo "[*] Attempting to read system.map from guest (kernel: $KERNEL_VER)..."
    SYS_MAP=$(guest_exec_capture "$GUEST" /bin/cat "/boot/System.map-${KERNEL_VER}" 2>/dev/null || true)
    if [ -n "$SYS_MAP" ]; then
        echo "$SYS_MAP" > "${SYMBOL_DIR}/system.map"
        echo "[+] system.map fetched via qemu-agent ($(wc -l < "${SYMBOL_DIR}/system.map") entries)"
    fi
fi

# Method 2: Use installed kernel RPM to extract
if [ ! -f "${SYMBOL_DIR}/system.map" ]; then
    echo "[*] Trying to extract system.map from kernel RPM..."
    cat > "${SYMBOL_DIR}/SYMBOLS_README.txt" << README
To fetch kernel symbols for ${GUEST} (kernel: ${KERNEL_VER:-unknown}):

Option 1: Inside the guest:
  cp /boot/System.map-${KERNEL_VER} /tmp/system.map
  # Then copy it out via virsh qemu-agent or SCP

Option 2: From the host (if kernel RPM available):
  rpm2cpio kernel-${KERNEL_VER}.rpm | cpio -idm ./boot/System.map-${KERNEL_VER}
  cp boot/System.map-${KERNEL_VER} ${SYMBOL_DIR}/system.map

Option 3: If guest is currently running (qemu-agent):
  ${0} ${GUEST} ${KERNEL_VER}
README
    echo "[!] Could not fetch symbols automatically."
    echo "    See ${SYMBOL_DIR}/SYMBOLS_README.txt for manual steps"
    exit 1
fi

# Verify symbols
echo "[*] Verifying symbols..."
if head -5 "${SYMBOL_DIR}/system.map" | grep -qE "T _stext|D _text|T _text"; then
    echo "[+] Symbols look valid"
    echo "    $(wc -l < "${SYMBOL_DIR}/system.map") entries"
else
    echo "[!] WARNING: Symbols may be invalid"
    head -3 "${SYMBOL_DIR}/system.map"
fi

echo "[+] Symbols saved to ${SYMBOL_DIR}/system.map"
