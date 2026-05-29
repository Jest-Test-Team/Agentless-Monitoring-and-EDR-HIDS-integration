#!/bin/bash
# run-risk-scanner.sh — Cron wrapper for risk-scanner
# Ships results via Filebeat to OpenSearch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/var/log/risk-scanner}"
LOCK_FILE="/tmp/risk-scanner-$(hostname).lock"
MODE="${1:---all}"

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    echo "[!] Another scan is already running (PID $(cat "$LOCK_FILE"))"
    exit 1
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

mkdir -p "$OUTPUT_DIR"

case "$MODE" in
    --all|-a)
        echo "[*] Running full risk scan..."
        bash "${SCRIPT_DIR}/risk-scanner.sh" all
        ;;
    --cve|-c)
        echo "[*] Running CVE-only scan..."
        bash "${SCRIPT_DIR}/risk-scanner.sh" cve
        ;;
    --quick|-q)
        echo "[*] Running quick scan (no trivy)..."
        bash "${SCRIPT_DIR}/risk-scanner.sh" quick
        ;;
    --dry-run|-d)
        echo "[*] Running dry-run (stdout only)..."
        bash "${SCRIPT_DIR}/risk-scanner.sh" dry-run
        ;;
    *)
        echo "Usage: $0 [--all|--cve|--quick|--dry-run]"
        echo "  --all (-a)     Full scan (default)"
        echo "  --cve (-c)     CVE scan only (trivy)"
        echo "  --quick (-q)   Quick scan (skip trivy)"
        echo "  --dry-run (-d) Print results to stdout, don't ship"
        exit 1
        ;;
esac

if [ "$MODE" != "--dry-run" ]; then
    # The JSON files are already written to OUTPUT_DIR
    # Filebeat picks them up automatically
    echo "[*] Results written to ${OUTPUT_DIR}/"
    echo "[*] Filebeat will ship to Logstash automatically"
fi

echo "[+] Done."
