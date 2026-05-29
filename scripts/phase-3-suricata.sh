#!/bin/bash
# Phase 3: Suricata NIDS Setup
# Configures Suricata for Tier 0 port mirror monitoring
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
TIER0_NETWORK="${2:-${TIER0_NET:-192.168.100.0/24}}"

echo "[*] Phase 3: Suricata NIDS Setup"
echo "  Mirror interface: $MIRROR_INTERFACE"
echo "  Tier 0 network:   $TIER0_NETWORK"
echo "========================================"

# Install Suricata
dnf install -y epel-release
dnf install -y suricata

# Create config
cat > /etc/suricata/suricata.yaml << SURI
%YAML 1.1
---
vars:
  address-groups:
    TIER0_NETWORK: "[${TIER0_NETWORK}]"
    EXTERNAL_NET: "!\$TIER0_NETWORK"

af-packet:
  - interface: ${MIRROR_INTERFACE}
    cluster-id: 99
    cluster-type: cluster_qm
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes
    rollover: yes
    buffer-size: 64512

rule-files:
  - suricata.rules
  - emerging-exploit.rules
  - emerging-malware.rules

engine:
  analysis:
    - http
    - dns
    - tls

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: /var/log/suricata/eve.json
      types:
        - alert:
            payload: yes
            payload-buffer-size: 4kb
        - http:
            extended: yes
        - dns:
            query: yes
            rdata: yes
        - tls:
            extended: yes
        - flow:
            modules: [tcp, udp]
        - files:
            force-magic: yes

app-layer:
  protocols:
    tls:
      enabled: yes
      ja3-fingerprints: yes
    dns:
      enabled: yes
    http:
      enabled: yes
    smb:
      enabled: yes

# Performance tuning
defrag:
  max-frags: 65536
stream:
  memcap: 1GB
  checksum-validation: yes
SURI

# Enable emerging threats rules
suricata-update update-source emergingthreats
suricata-update enable-source emergingthreats
suricata-update

# Configure interface
cat > /etc/sysconfig/network-scripts/ifcfg-${MIRROR_INTERFACE} << 'IFCFG' || true
# Mirror interface - configured by network team
# This should be the SPAN destination port
ONBOOT=yes
DEVICE=${MIRROR_INTERFACE}
TYPE=Ethernet
BOOTPROTO=none
MTU=9000
IFCFG

# Enable & start
systemctl enable suricata
systemctl start suricata

echo "[+] Suricata NIDS configured on ${MIRROR_INTERFACE}"
echo "    Verify: tail -f /var/log/suricata/eve.json"
echo "    Stats:  suricatasc -c get-stats"
