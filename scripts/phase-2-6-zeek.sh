#!/bin/bash
# Phase 2.6: Zeek NIDS Deployment (alternative/complement to Suricata)
# Installs Zeek, configures for mirror interface, integrates with Filebeat+Logstash
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

MIRROR_INTERFACE="${1:-${ZEEK_MIRROR_INTERFACE:-bond0.100}}"
ZEEK_LOG_DIR="${ZEEK_LOG_DIR:-/var/log/zeek}"
ZEEK_CFG_DIR="${ZEEK_CFG_DIR:-/etc/zeek}"
ZEEK_SCRIPT_DIR="${ZEEK_SCRIPT_DIR:-/usr/share/zeek/site}"

echo "[*] Phase 2.6: Zeek NIDS Setup"
echo "  Mirror interface: $MIRROR_INTERFACE"
echo "  Log directory:    $ZEEK_LOG_DIR"
echo "========================================"

# Install Zeek via official repo
if ! command -v zeek &>/dev/null; then
    echo "  [*] Installing Zeek..."
    dnf install -y curl gnupg
    curl -fsSL https://download.zeek.org/zeek.asc | rpm --import -
    cat > /etc/yum.repos.d/zeek.repo << 'REPO'
[zeek]
name=Zeek
baseurl=https://download.zeek.org/zeek/el/$releasever/$basearch/
enabled=1
gpgcheck=1
REPO
    dnf install -y zeek
fi

ZEEK_BIN=$(command -v zeek 2>/dev/null || command -v zeekctl 2>/dev/null || echo "/opt/zeek/bin/zeek")

echo "  [*] Zeek binary: $ZEEK_BIN"

# Set up Zeek configuration
mkdir -p "$ZEEK_CFG_DIR" "$ZEEK_LOG_DIR"

# Write networks.cfg
cat > "${ZEEK_CFG_DIR}/networks.cfg" << NETCFG
# Local networks for Zeek
${TIER0_NET:-192.168.100.0/24}  Tier0-VMI-Network
${TIER1_NET:-172.16.0.0/16}     Tier1-Internal
${TIER2_NET:-10.0.0.0/24}       Tier2-BareMetal
NETCFG

# Write node.cfg
cat > "${ZEEK_CFG_DIR}/node.cfg" << NODECFG
[zeek]
type=standalone
host=localhost
interface=$MIRROR_INTERFACE
lb_method=pf_ring
lb_procs=4
pin_cpus=0,1,2,3
NODECFG

# Write main Zeek script for deployment
cat > "${ZEEK_SCRIPT_DIR}/local.zeek" << 'ZEEKSCRIPT'
@load packages
@load policy/frameworks/software/vulnerable
@load policy/frameworks/files/hash-all-files
@load policy/protocols/conn/known-hosts
@load policy/protocols/conn/known-services
@load policy/protocols/ssl/known-certs
@load policy/protocols/ssl/validate-certs
@load policy/protocols/http/software
@load policy/protocols/http/detect-webapps
@load policy/protocols/dns/detect-external-names
@load policy/protocols/ftp/software
@load policy/protocols/smb
@load policy/protocols/ssh/interesting-hostnames
@load policy/protocols/ssh/geo-data
@load policy/tuning/json-logs

# Custom event filtering
event connection_established(c: connection) {
    if ( c$id$resp_h in 192.168.0.0/16 || c$id$resp_h in 10.0.0.0/8 ) {
        return;
    }
    NOTICE([$note=ExternalConnection,
            $msg=fmt("External connection from %s to %s",
                      c$id$orig_h, c$id$resp_h),
            $conn=c]);
}

# Log rotation trigger
event zeek_done() {
    print fmt("Zeek shutdown at %s", strftime("%Y-%m-%d %H:%M:%S", current_time()));
}
ZEEKSCRIPT

# Write zeekctl config
cat > "${ZEEK_CFG_DIR}/zeekctl.cfg" << CTRLCFG
LogDir = $ZEEK_LOG_DIR
ConfigDir = $ZEEK_CFG_DIR
SiteDir = $ZEEK_SCRIPT_DIR
SpoolDir = /var/spool/zeek
SeedsDir = /var/spool/zeek/seeds
lb_custom.InterfacePrefix = afpacket
PinCpu = 1
CTRLCFG

# Create spool directory
mkdir -p /var/spool/zeek/seeds

# Set up log rotation (keep 30 days)
cat > /etc/logrotate.d/zeek << LOGROTATE
$ZEEK_LOG_DIR/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        zeekctl deploy 2>/dev/null || true
    endscript
}
LOGROTATE

# Configure Filebeat for Zeek logs
FILEBEAT_CONF="${FILEBEAT_CONF:-/etc/filebeat/filebeat.yml}"
if [ -f "$FILEBEAT_CONF" ]; then
    cat >> "$FILEBEAT_CONF" << 'FILEBEAT'

# Zeek NIDS input
- type: log
  enabled: true
  paths:
    - /var/log/zeek/*.log
  fields:
    log_type: zeek
  fields_under_root: true
  multiline:
    pattern: '^#'
    negate: true
    match: after
FILEBEAT
    echo "  [*] Added Zeek log input to $FILEBEAT_CONF"
fi

# Enable and start Zeek
systemctl enable zeek 2>/dev/null || true
zeekctl deploy 2>/dev/null || zeekctl install 2>/dev/null || true
echo "  [*] Zeek deployed (check: zeekctl status)"

echo "[+] Zeek NIDS configured on ${MIRROR_INTERFACE}"
echo "    Logs:        ${ZEEK_LOG_DIR}/"
echo "    Verify:      zeekctl status"
echo "    Test event:  zeek -i ${MIRROR_INTERFACE} -C ${ZEEK_SCRIPT_DIR}/local.zeek"
echo ""
echo "    Integration:"
echo "    - Filebeat ships ${ZEEK_LOG_DIR}/*.log to Logstash"
echo "    - Logstash pipeline tag: log_type=zeek (add filter block in 02-filters.conf)"
echo "    - Example filter:"
echo '      if [log_type] == "zeek" {'
echo '        json { source => "message" }'
echo '        date { match => ["ts", "UNIX"] }'
echo "      }"
