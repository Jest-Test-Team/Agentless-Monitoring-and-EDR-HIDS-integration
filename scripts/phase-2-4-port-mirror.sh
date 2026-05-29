#!/bin/bash
# Phase 2.4: Port Mirror / SPAN Configuration
# Sets up network traffic mirroring for Suricata NIDS monitoring
# Supports both Linux bridge mirroring and generates switch CLI config
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

MIRROR_INTERFACE="${1:-${SURICATA_MIRROR_INTERFACE:-bond0.100}}"
SOURCE_BRIDGE="${SOURCE_BRIDGE:-br0}"
VLAN_ID="${VLAN_ID:-100}"

echo "[*] Phase 2.4: Port Mirror / SPAN Configuration"
echo "  Mirror interface: $MIRROR_INTERFACE"
echo "  Source bridge: $SOURCE_BRIDGE"
echo "  VLAN: $VLAN_ID"
echo "========================================"

# Check if the mirror interface already exists
if ip link show "$MIRROR_INTERFACE" &>/dev/null; then
    echo "[*] Mirror interface $MIRROR_INTERFACE already exists"
else
    echo "[*] Creating VLAN interface $MIRROR_INTERFACE..."

    # Option A: VLAN on bond
    if ip link show "${MIRROR_INTERFACE%%.*}" &>/dev/null; then
        ip link add link "${MIRROR_INTERFACE%%.*}" name "$MIRROR_INTERFACE" type vlan id "$VLAN_ID"
        ip link set "$MIRROR_INTERFACE" promisc on
        ip link set "$MIRROR_INTERFACE" up
        echo "[+] VLAN interface $MIRROR_INTERFACE created on ${MIRROR_INTERFACE%%.*}"
    # Option B: VLAN on bridge port
    elif ip link show "$SOURCE_BRIDGE" &>/dev/null; then
        ip link add link "$SOURCE_BRIDGE" name "$MIRROR_INTERFACE" type vlan id "$VLAN_ID"
        ip link set "$MIRROR_INTERFACE" promisc on
        ip link set "$MIRROR_INTERFACE" up
        echo "[+] VLAN interface $MIRROR_INTERFACE created on $SOURCE_BRIDGE"
    else
        echo "[!] Could not find parent interface for $MIRROR_INTERFACE"
        echo "    Create manually: ip link add link <parent> name $MIRROR_INTERFACE type vlan id $VLAN_ID"
    fi
fi

# Configure tc mirred (ingress mirroring on bridge)
echo "[*] Configuring tc mirroring on $SOURCE_BRIDGE -> $MIRROR_INTERFACE..."
if ip link show "$SOURCE_BRIDGE" &>/dev/null; then
    # Add qdisc and mirror filter on bridge ingress
    tc qdisc add dev "$SOURCE_BRIDGE" ingress 2>/dev/null || true
    tc filter add dev "$SOURCE_BRIDGE" parent ffff: protocol all \
        matchall skip_sw \
        action mirred egress mirror dev "$MIRROR_INTERFACE" 2>/dev/null || \
    tc filter add dev "$SOURCE_BRIDGE" parent ffff: protocol all \
        matchall \
        action mirred egress mirror dev "$MIRROR_INTERFACE" 2>/dev/null || \
    echo "[!] tc mirroring failed — this kernel may not support matchall"
    echo "[+] tc mirror configured: $SOURCE_BRIDGE -> $MIRROR_INTERFACE"
else
    echo "[!] Bridge $SOURCE_BRIDGE not found; tc mirror will not work"
fi

# Generate switch-side Cisco CLI configuration
SWITCH_CONF="/etc/suricata/switch-span-config.txt"
cat > "$SWITCH_CONF" << 'SWITCH'
! Cisco Switch SPAN Configuration
! Apply to the switch that connects Tier 0 VMs
!
! Monitor all VM traffic
monitor session 1 source interface Gi1/0/1 - 24
monitor session 1 destination interface Gi1/0/48
!
! If using VLAN-based SPAN:
! monitor session 1 source vlan 100
! monitor session 1 destination interface Gi1/0/48
!
! For high availability with dual Suricata hosts:
! monitor session 1 destination interface Po1  (port-channel to both hosts)
!
! Verify:
! show monitor session 1
! show interfaces Gi1/0/48
SWITCH
echo "[+] Switch config saved to $SWITCH_CONF"

# Persist Linux mirror config (rc.local fallback)
RC_LOCAL="/etc/rc.d/rc.local"
if [ -f "$RC_LOCAL" ]; then
    if ! grep -q "$MIRROR_INTERFACE" "$RC_LOCAL" 2>/dev/null; then
        cat >> "$RC_LOCAL" << 'RCLOCAL'
# Port mirror for Suricata NIDS (phase-2-4-port-mirror.sh)
ip link set MIRROR_IFACE promisc on
ip link set MIRROR_IFACE up
RCLOCAL
        sed -i "s/MIRROR_IFACE/$MIRROR_INTERFACE/" "$RC_LOCAL"
        chmod +x "$RC_LOCAL"
        echo "[+] Mirror config persisted to $RC_LOCAL"
    fi
fi

echo "[+] Port mirror setup complete"
echo "    Verify: tcpdump -i $MIRROR_INTERFACE -c 10"
echo "    Suricata will listen on: $MIRROR_INTERFACE"
