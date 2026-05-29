#!/bin/bash
# Utility: DRAKVUF State Backup (periodic introspection state persistence)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_PATH="/etc/agentless/deploy.conf"
if [ -f "$CONF_PATH" ]; then
    source "$CONF_PATH"
elif [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

GUEST="${1:?Usage: $0 <guest-name> [interval-seconds]}"
INTERVAL="${2:-300}"
BACKUP_DIR="${DRAKVUF_STATE_DIR:-/var/lib/drakvuf/state-backups}/${GUEST}"
STATE_SOCKET="/tmp/drakvuf-${GUEST}.sock"

mkdir -p "$BACKUP_DIR"

echo "[*] DRAKVUF State Backup Daemon for ${GUEST}"
echo "  Interval: ${INTERVAL}s"
echo "  Backup dir: ${BACKUP_DIR}"
echo "  Socket: ${STATE_SOCKET}"
echo "========================================"

# Check if DRAKVUF is running with --state-socket
if [ ! -S "$STATE_SOCKET" ] && ! pgrep -f "drakvuf.*-r ${GUEST}" > /dev/null; then
    echo "[!] DRAKVUF not running for ${GUEST}"
    exit 1
fi

while true; do
    TIMESTAMP=$(date +%s)
    BACKUP_FILE="${BACKUP_DIR}/state-${TIMESTAMP}.json"

    if [ -S "$STATE_SOCKET" ]; then
        # Use state socket if available (requires DRAKVUF built with --enable-state-socket)
        echo "{\"cmd\":\"dump_state\"}" | socat - UNIX-CONNECT:"$STATE_SOCKET" > "$BACKUP_FILE" 2>/dev/null
        
        if [ -s "$BACKUP_FILE" ] && head -1 "$BACKUP_FILE" | grep -q "state"; then
            echo "[$(date)] State backed up: ${TIMESTAMP}"
        else
            rm -f "$BACKUP_FILE"
        fi
    else
        # Fallback: save the running process list from DRAKVUF stats
        STATS_FILE="/var/log/drakvuf/${GUEST}-stats.json"
        if [ -f "$STATS_FILE" ]; then
            cp "$STATS_FILE" "${BACKUP_DIR}/stats-${TIMESTAMP}.json"
        fi
    fi

    # Rotate: keep last 10
    ls -t "$BACKUP_DIR"/*.json 2>/dev/null | tail -n +11 | xargs -I{} rm {} 2>/dev/null || true

    sleep "$INTERVAL"
done
