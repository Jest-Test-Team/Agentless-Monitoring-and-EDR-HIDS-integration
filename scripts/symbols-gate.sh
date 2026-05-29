#!/bin/bash
# Utility: Kernel Symbol Validation Gate
# Run BEFORE any production kernel update
set -euo pipefail

GUEST="${1:?Usage: $0 <guest-name> <new-system-map> <old-system-map>}"
NEW_MAP="$2"
OLD_MAP="$3"

echo "[*] Symbol Validation Gate for ${GUEST}"
echo "  New: $NEW_MAP"
echo "  Old: $OLD_MAP"
echo "========================================"

# 1. Check file exists
[ -f "$NEW_MAP" ] || { echo "[FAIL] New symbol file not found"; exit 1; }
[ -f "$OLD_MAP" ] || echo "[WARN] Old symbol file not found, skipping diff"

# 2. Validate format (Linux system.map)
echo "[*] Validating system.map format..."
HEADER=$(head -1 "$NEW_MAP" 2>/dev/null || echo "")
if echo "$HEADER" | grep -qE '^[0-9a-fA-F]{8,16}\s+[A-Za-z]\s+'; then
    echo "[OK] Format looks valid"
else
    echo "[FAIL] Invalid format (expected: 'address type symbol')"
    echo "  First line: $HEADER"
    exit 1
fi

# 3. Count symbols
TOTAL=$(wc -l < "$NEW_MAP")
echo "[*] Total symbols: $TOTAL"

# 4. Check critical symbols exist
CRITICAL_SYMBOLS=(
    "_stext"
    "_etext"
    "init_task"
    "sys_call_table"
    "security_ops"
    "do_sys_open"
    "do_execve"
    "do_fork"
    "__schedule"
    "kallsyms_lookup_name"
)

MISSING=0
for sym in "${CRITICAL_SYMBOLS[@]}"; do
    if grep -qE "\s+[A-Za-z]\s+${sym}$" "$NEW_MAP"; then
        echo "[OK] Critical symbol found: $sym"
    else
        echo "[FAIL] Critical symbol missing: $sym"
        MISSING=$((MISSING+1))
    fi
done

# 5. Diff with old (if available)
if [ -f "$OLD_MAP" ]; then
    echo "[*] Comparing with old symbols..."
    OLD_TOTAL=$(wc -l < "$OLD_MAP")
    DIFF=$((TOTAL - OLD_TOTAL))
    echo "  Old: $OLD_TOTAL symbols  New: $TOTAL symbols  Diff: ${DIFF}"

    # Check for large structural changes in key offsets
    for sym in "init_task" "sys_call_table"; do
        OLD_ADDR=$(grep -E "\s+[A-Za-z]\s+${sym}$" "$OLD_MAP" | awk '{print $1}')
        NEW_ADDR=$(grep -E "\s+[A-Za-z]\s+${sym}$" "$NEW_MAP" | awk '{print $1}')
        if [ -n "$OLD_ADDR" ] && [ -n "$NEW_ADDR" ] && [ "$OLD_ADDR" != "$NEW_ADDR" ]; then
            echo "[INFO] Symbol ${sym} moved: ${OLD_ADDR} -> ${NEW_ADDR}"
        fi
    done
fi

# Decision
if [ "$MISSING" -gt 0 ]; then
    echo "[GATE FAIL] ${MISSING} critical symbols missing"
    echo "  Do NOT deploy this kernel update"
    exit 1
else
    echo "[GATE PASS] All critical symbols present"
fi
