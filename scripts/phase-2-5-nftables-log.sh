#!/bin/bash
# Phase 2.5: nftables Connection Logging for Tier 2 Bare Metal
# Sets up nftables rule to log all new connections for security monitoring
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

RULESET_FILE="/etc/nftables/conf.d/10-connection-logging.conf"
LOG_PREFIX="NFT_TIER2"

echo "[*] Phase 2.5: nftables Connection Logging"
echo "  Ruleset: $RULESET_FILE"
echo "  Syslog prefix: $LOG_PREFIX"
echo "========================================"

# Ensure nftables is installed
if ! command -v nft &>/dev/null; then
    dnf install -y nftables
fi

mkdir -p /etc/nftables/conf.d

# Write nftables logging ruleset
cat > "$RULESET_FILE" << 'NFT'
# Tier 2 connection logging ruleset
# Logs all new TCP/UDP connections to syslog
table inet filter {
    set log_skip_ports {
        type inet_service
        flags constant
        elements = { 53, 123, 67, 68 }
    }

    chain input {
        type filter hook input priority 0; policy accept;

        # Log new TCP connections to non-ephemeral ports
        tcp dport > 1024 ct state new log prefix "NFT_TCP_IN: " accept
        tcp dport <= 1024 ct state new log prefix "NFT_TCP_IN_SVC: " accept

        # Log new UDP flows
        udp ct state new log prefix "NFT_UDP_IN: " accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state new log prefix "NFT_FWD: " accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
        ct state new tcp dport > 1024 log prefix "NFT_TCP_OUT: " accept
    }
}
NFT

# Include in main nftables config
MAIN_CONF="/etc/nftables/main.nft"
if [ -f "$MAIN_CONF" ]; then
    if ! grep -q "10-connection-logging" "$MAIN_CONF" 2>/dev/null; then
        echo "include \"$RULESET_FILE\"" >> "$MAIN_CONF"
    fi
else
    # Create main config that includes the logging ruleset
    cat > /etc/nftables/main.nft << 'MAIN'
#!/usr/sbin/nft -f
include "/etc/nftables/conf.d/10-connection-logging.conf"
MAIN
fi

# Ensure nftables service reads our config
if [ -f /etc/sysconfig/nftables.conf ]; then
    if ! grep -q "main.nft" /etc/sysconfig/nftables.conf 2>/dev/null; then
        echo "NFTABLES_MAIN=/etc/nftables/main.nft" >> /etc/sysconfig/nftables.conf
    fi
fi

systemctl enable nftables
systemctl restart nftables

# Configure rsyslog to separate nftables logs
cat > /etc/rsyslog.d/30-nftables.conf << 'RSYS'
:msg, contains, "NFT_" /var/log/nftables.log
& stop
RSYS
systemctl restart rsyslog

# Logrotate for nftables log
cat > /etc/logrotate.d/nftables << 'LOGROTATE'
/var/log/nftables.log {
    rotate 30
    daily
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        /usr/bin/systemctl restart rsyslog > /dev/null 2>&1 || true
    endscript
}
LOGROTATE

echo "[+] nftables connection logging deployed"
echo "    Verify: nft list ruleset"
echo "    View logs: tail -f /var/log/nftables.log"
