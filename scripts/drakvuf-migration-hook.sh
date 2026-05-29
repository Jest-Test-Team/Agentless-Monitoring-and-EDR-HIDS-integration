#!/bin/bash
# Utility: DRAKVUF Migration Hook (for libvirtd pre/post migration)
# WARNING: DRAKVUF does NOT support live migration natively
# This is a best-effort to save/restore state
set -euo pipefail

GUEST="${1:?Usage: $0 <guest-name> <action>}"
ACTION="${2:?Actions: pre-migrate | post-migrate | pre-start | post-stop}"

BACKUP_DIR="/var/lib/drakvuf/state-backups/${GUEST}"
STATE_SOCKET="/tmp/drakvuf-${GUEST}.sock"

echo "[*] Migration Hook: ${GUEST} -> ${ACTION}"
echo "========================================"

case "$ACTION" in
    pre-migrate)
        echo "[*] Pre-migration: saving state..."
        mkdir -p "$BACKUP_DIR"
        if [ -S "$STATE_SOCKET" ]; then
            socat - UNIX-CONNECT:"$STATE_SOCKET" <<< '{"cmd":"dump_state"}' \
                > "${BACKUP_DIR}/pre-migrate-$(date +%s).json" 2>/dev/null
            socat - UNIX-CONNECT:"$STATE_SOCKET" <<< '{"cmd":"pause"}'
            echo "[*] DRAKVUF introspection paused"
        else
            systemctl stop "drakvuf@${GUEST}"
            echo "[*] DRAKVUF stopped for migration"
        fi
        ;;

    post-migrate)
        echo "[*] Post-migration: resuming..."
        # Try to resume from latest state backup
        LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/pre-migrate-*.json 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
            echo "[*] Resuming from state: $LATEST_BACKUP"
            systemctl start "drakvuf@${GUEST}"
        else
            echo "[!] No state backup found, cold starting DRAKVUF"
            systemctl start "drakvuf@${GUEST}"
        fi
        # Restart state backup daemon
        nohup /usr/local/bin/drakvuf-state-backup.sh "${GUEST}" 300 &
        ;;

    pre-start)
        echo "[*] Pre-start: ensuring clean state..."
        rm -f "${STATE_SOCKET}"
        ;;

    post-stop)
        echo "[*] Post-stop: cleaning up..."
        if [ -S "$STATE_SOCKET" ]; then
            socat - UNIX-CONNECT:"$STATE_SOCKET" <<< '{"cmd":"shutdown"}'
        fi
        ;;
esac

echo "[*] Migration hook complete"
