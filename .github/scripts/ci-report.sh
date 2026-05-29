#!/bin/bash
# ci-report.sh — Generate CI report with coverage analysis and suggestions
# Portable: uses files for storage instead of bash 4+ associative arrays
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

REPORT_FILE="${1:-ci-report.md}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "[*] Generating CI report -> $REPORT_FILE"

# ── Helper functions ──
count_scripts() { find scripts -maxdepth 1 \( -name "*.sh" -o -name "*.py" \) 2>/dev/null | wc -l; }
count_configs() { find configs -type f 2>/dev/null | wc -l; }
count_docs() { ls docs/*.md 2>/dev/null | wc -l; }

check_bash_syntax() {
    local f="$1"
    bash -n "$f" 2>/dev/null && echo "PASS" || echo "FAIL"
}

check_python_syntax() {
    local f="$1"
    python3 -m py_compile "$f" 2>/dev/null && echo "PASS" || echo "FAIL"
}

check_yaml_syntax() {
    local f="$1"
    python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null && echo "PASS" || echo "FAIL"
}

# ── Gather stats ──
TOTAL_SCRIPTS=$(count_scripts)
TOTAL_CONFIGS=$(count_configs)
TOTAL_DOCS=$(count_docs)
BASH_SCRIPTS=$(find scripts -maxdepth 1 -name "*.sh" 2>/dev/null | wc -l)
PYTHON_SCRIPTS=$(find scripts -maxdepth 1 -name "*.py" 2>/dev/null | wc -l)

# Tier coverage analysis — store as tier_name|file1 file2 ... in temp files
echo "[*] Analyzing tier coverage..."
cat > "$TMPDIR/tiers" << 'TIERS'
Tier 0 (DRAKVUF+NIDS)|phase-0-check.sh phase-1-1-kvmi-kernel.sh phase-1-2-host-hardening.sh phase-1-3-dom0-monitoring.sh phase-2-1-drakvuf-install.sh phase-2-2-drakvuf-config.sh phase-2-3-vm-setup.sh phase-2-4-port-mirror.sh phase-3-suricata.sh phase-5-1-filebeat.sh check-vmi-compatibility.sh symbols-gate.sh fetch-linux-symbols.sh fetch-windows-symbols.py drakvuf-state-backup.sh drakvuf-migration-hook.sh
Tier 1 (Wazuh+Osquery+Auditd)|phase-4-wazuh-deploy.sh phase-4-wazuh-manager.sh configs/auditd/rules.d/tier1-audit.rules run-risk-scanner.sh risk-scanner.sh risk-lib.sh risk-score-engine.py
Tier 2 (Bare Metal HIDS)|phase-4-wazuh-deploy.sh configs/auditd/rules.d/tier2-audit.rules configs/aide/aide.conf phase-2-5-nftables-log.sh run-risk-scanner.sh risk-scanner.sh risk-lib.sh risk-score-engine.py
Tier 3 (Dev/Test)|phase-4-wazuh-deploy.sh phase-4-1-rsyslog-tier3.sh configs/wazuh/ossec.conf.tier3
Edge/IoT|deploy-edge-agent.sh configs/wazuh/ossec.conf.edge configs/docker/docker-compose.edge-agent.yml docs/EDGE-DEVICE-GUIDE.md build-offline-bundle.sh
Central Stack|phase-5-1-filebeat.sh phase-5-2-logstash.sh phase-5-3-redis-buffer.sh phase-6-healthcheck.sh deploy.conf
Ansible Multi-Host|ansible/site.yml ansible/playbooks/tier0-playbook.yml ansible/playbooks/tier1-playbook.yml ansible/playbooks/tier2-playbook.yml ansible/playbooks/tier3-playbook.yml ansible/inventory/hosts.ini deploy-all.sh
TIERS

# ── Syntax validation ──
echo "[*] Running syntax validation..."

# Shell scripts
echo "--- shell ---" > "$TMPDIR/bash.txt"
BASH_FAIL=0
BASH_TOTAL=0
while IFS= read -r f; do
    result=$(check_bash_syntax "$f")
    echo "$f|$result" >> "$TMPDIR/bash.txt"
    BASH_TOTAL=$((BASH_TOTAL + 1))
    [ "$result" = "FAIL" ] && BASH_FAIL=$((BASH_FAIL + 1))
done < <(find scripts -maxdepth 1 -name "*.sh" 2>/dev/null)

# Python scripts
echo "--- python ---" > "$TMPDIR/python.txt"
PY_FAIL=0
PY_TOTAL=0
while IFS= read -r f; do
    result=$(check_python_syntax "$f")
    echo "$f|$result" >> "$TMPDIR/python.txt"
    PY_TOTAL=$((PY_TOTAL + 1))
    [ "$result" = "FAIL" ] && PY_FAIL=$((PY_FAIL + 1))
done < <(find scripts -maxdepth 1 -name "*.py" 2>/dev/null)

# YAML files
echo "--- yaml ---" > "$TMPDIR/yaml.txt"
YAML_FAIL=0
YAML_TOTAL=0
while IFS= read -r f; do
    result=$(check_yaml_syntax "$f")
    echo "$f|$result" >> "$TMPDIR/yaml.txt"
    YAML_TOTAL=$((YAML_TOTAL + 1))
    [ "$result" = "FAIL" ] && YAML_FAIL=$((YAML_FAIL + 1))
done < <(find . -name "*.yml" -o -name "*.yaml" 2>/dev/null | grep -v node_modules | grep -v __pycache__)

# ── Generate suggestions ──
SUGGESTIONS=""

if [ ! -f "scripts/phase-2-6-zeek.sh" ]; then
    SUGGESTIONS="${SUGGESTIONS}- [suggestion] Zeek NIDS alternative not yet scripted (see docs for manual setup)\n"
fi
if ! grep -q "Sysmon" docs/*.md 2>/dev/null; then
    SUGGESTIONS="${SUGGESTIONS}- [info] Windows Sysmon guide exists in docs/WINDOWS-TIER2.md\n"
fi
if [ ! -f "tests/test_logstash_pipeline.py" ]; then
    SUGGESTIONS="${SUGGESTIONS}- [suggestion] Add Logstash pipeline unit tests (validate config parsing)\n"
fi
if ! grep -q "kafka" scripts/deploy.conf 2>/dev/null; then
    SUGGESTIONS="${SUGGESTIONS}- [info] Using Redis buffer (<10K eps); add Kafka option in deploy.conf for higher scale\n"
fi
if ! grep -q "ansible-lint" .github/workflows/*.yml 2>/dev/null; then
    SUGGESTIONS="${SUGGESTIONS}- [suggestion] Add ansible-lint to CI pipeline\n"
fi

# ── Write report ──
cat > "$REPORT_FILE" << REPORT
# CI Report — Agentless Monitoring & EDR/HIDS Integration

**Generated:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')
**Commit:** $(git rev-parse HEAD 2>/dev/null || echo "unknown")

## Overview

| Metric | Value |
|--------|-------|
| Total Scripts | $TOTAL_SCRIPTS |
| Shell Scripts | $BASH_SCRIPTS |
| Python Scripts | $PYTHON_SCRIPTS |
| Config Files | $TOTAL_CONFIGS |
| Documents | $TOTAL_DOCS |
| Ansible Files | $(find ansible -type f 2>/dev/null | wc -l) |

## Tier Coverage

| Tier | Status | Key Components |
|------|--------|----------------|
REPORT

while IFS='|' read -r tier components; do
    present=0
    missing=0
    missing_list=""
    for comp in $components; do
        if [ -f "$comp" ] || [ -d "$comp" ]; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
            missing_list="${missing_list}${comp} "
        fi
    done
    total=$((present + missing))
    if [ "$total" -gt 0 ]; then
        pct=$((present * 100 / total))
    else
        pct=0
    fi
    [ "$missing" -gt 0 ] && status="⚠️ ${pct}%" || status="✅ Complete"
    echo "| $tier | $status | ${present}/${total} files present${missing_list:+ (missing: ${missing_list})} |" >> "$REPORT_FILE"
done < "$TMPDIR/tiers"

cat >> "$REPORT_FILE" << REPORT

## Syntax Validation

### Shell Scripts (\`bash -n\`)
REPORT

if [ "$BASH_FAIL" -gt 0 ]; then
    echo "**${BASH_FAIL}/${BASH_TOTAL} scripts FAILED syntax check**" >> "$REPORT_FILE"
    while IFS='|' read -r f result; do
        case "$f" in ---*) continue ;; esac
        [ "$result" = "FAIL" ] && echo "- \`$f\` — SYNTAX ERROR" >> "$REPORT_FILE"
    done < "$TMPDIR/bash.txt"
else
    echo "**All ${BASH_TOTAL} shell scripts pass syntax check** ✅" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << REPORT

### Python Scripts (\`python3 -m py_compile\`)
REPORT

if [ "$PY_FAIL" -gt 0 ]; then
    echo "**${PY_FAIL}/${PY_TOTAL} scripts FAILED**" >> "$REPORT_FILE"
    while IFS='|' read -r f result; do
        case "$f" in ---*) continue ;; esac
        [ "$result" = "FAIL" ] && echo "- \`$f\` — SYNTAX ERROR" >> "$REPORT_FILE"
    done < "$TMPDIR/python.txt"
else
    echo "**All ${PY_TOTAL} Python scripts pass syntax check** ✅" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << REPORT

### YAML Files
REPORT

if [ "$YAML_FAIL" -gt 0 ]; then
    echo "**${YAML_FAIL}/${YAML_TOTAL} files FAILED**" >> "$REPORT_FILE"
    for f in "${!YAML_RESULTS[@]}"; do
        [ "${YAML_RESULTS[$f]}" = "FAIL" ] && echo "- \`$f\` — SYNTAX ERROR" >> "$REPORT_FILE"
    done
else
    echo "**All ${YAML_TOTAL} YAML files pass syntax check** ✅" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << REPORT

## Suggestions
REPORT

if [ -n "$SUGGESTIONS" ]; then
    echo -e "$SUGGESTIONS" >> "$REPORT_FILE"
else
    echo "No suggestions at this time." >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << REPORT

## Risk Score Engine Test Results

\`\`\`
$(cd tests && python3 test_risk_score_engine.py 2>&1 || echo "Test runner not available")
\`\`\`

## Summary

| Check | Status |
|-------|--------|
| Shell Syntax | ${BASH_FAIL}/${BASH_TOTAL} failed |
| Python Syntax | ${PY_FAIL}/${PY_TOTAL} failed |
| YAML Syntax | ${YAML_FAIL}/${YAML_TOTAL} failed |
| Risk Engine Tests | $(cd tests && python3 test_risk_score_engine.py 2>&1 | tail -1 || echo "N/A") |
REPORT

echo "[+] Report written: $REPORT_FILE ($(wc -l < "$REPORT_FILE") lines)"
