#!/bin/bash
# risk-lib.sh — Reusable Security Check Functions for risk-scanner
# Source this file: source /usr/local/lib/risk-lib.sh
set -euo pipefail

# ── Globals ──
FINDINGS=()
CATEGORY=""

# ── Helpers ──

log_finding() {
    local severity="$1" check_id="$2" description="$3" weight="$4" detail="$5" recommendation="$6"
    FINDINGS+=("$(cat <<-EOF
{"severity":"$severity","check_id":"$check_id","description":"$description","weight":$weight,"category":"$CATEGORY","detail":"$(echo "$detail" | sed 's/"/\\"/g')","recommendation":"$(echo "$recommendation" | sed 's/"/\\"/g')"}
EOF
)")
}

pass()   { log_finding "low"    "$1" "$2" 1 "$3" "$4"; }
warn()   { log_finding "medium" "$1" "$2" 2 "$3" "$4"; }
fail()   { log_finding "high"   "$1" "$2" 3 "$3" "$4"; }
crit()   { log_finding "critical" "$1" "$2" 4 "$3" "$4"; }

# ── CAT_A: System Hardening ──

check_kernel_params() {
    CATEGORY="system_hardening"
    local param="$1" expected="$2" desc="$3" rec="$4"
    local actual
    actual=$(sysctl -n "$param" 2>/dev/null || echo "NOT_FOUND")
    if [ "$actual" == "$expected" ]; then
        pass "KERNEL_$(echo "$param" | tr '.' '_')" "$desc = $actual" "$rec"
    else
        fail "KERNEL_$(echo "$param" | tr '.' '_')" "$desc = $actual (expected: $expected)" "$rec"
    fi
}

check_file_perms() {
    CATEGORY="system_hardening"
    local path="$1" expected_perm="$2" desc="$3" rec="$4"
    if [ ! -e "$path" ]; then
        warn "FILE_$(echo "$path" | tr '/' '_')" "$desc: file not found" "$rec"
        return
    fi
    local actual
    actual=$(stat -c "%a" "$path" 2>/dev/null || echo "000")
    if [ "$actual" -le "$expected_perm" ] 2>/dev/null; then
        pass "FILE_$(echo "$path" | tr '/' '_')" "$desc ($actual ≤ $expected_perm)" "$rec"
    else
        fail "FILE_$(echo "$path" | tr '/' '_')" "$desc: $actual (expected: ≤ $expected_perm)" "$rec"
    fi
}

check_suid() {
    CATEGORY="system_hardening"
    local known_suid="/usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/mount /usr/bin/umount /usr/bin/ping /bin/su /bin/ping /usr/sbin/unix_chkpwd"
    local findings_file
    findings_file=$(mktemp)
    find / -perm -4000 -type f 2>/dev/null > "$findings_file"
    while IFS= read -r f; do
        if ! echo "$known_suid" | grep -qF "$f"; then
            warn "SUID_ANOMALY" "Unexpected SUID binary: $f" "Investigate and remove SUID bit if unnecessary: chmod u-s $f"
        fi
    done < "$findings_file"
    local count
    count=$(wc -l < "$findings_file")
    pass "SUID_COUNT" "SUID binaries: $count" ""
    rm -f "$findings_file"
}

check_ssh_config() {
    CATEGORY="system_hardening"
    local param="$1" expected="$2" desc="$3" rec="$4"
    local actual
    actual=$(sshd -T 2>/dev/null | grep -i "^${param}" | awk '{print $2}' || echo "NOT_FOUND")
    if echo "$actual" | grep -qi "$expected"; then
        pass "SSH_$(echo "$param" | tr ' ' '_')" "$desc = $actual" "$rec"
    else
        fail "SSH_$(echo "$param" | tr ' ' '_')" "$desc = $actual (expected: $expected)" "$rec"
    fi
}

check_selinux() {
    CATEGORY="system_hardening"
    local status
    if command -v getenforce &>/dev/null; then
        status=$(getenforce)
        if [ "$status" == "Enforcing" ]; then
            pass "SELINUX_STATUS" "SELinux: $status" ""
        else
            fail "SELINUX_STATUS" "SELinux: $status (expected: Enforcing)" "setenforce 1 && sed -i 's/SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config"
        fi
    else
        warn "SELINUX_STATUS" "SELinux not found" "Install SELinux utilities"
    fi
}

check_users() {
    CATEGORY="system_hardening"
    # Users with UID 0 (should only be root)
    local uid0
    uid0=$(awk -F: '($3 == 0) {print $1}' /etc/passwd | grep -v '^root$' || true)
    if [ -n "$uid0" ]; then
        fail "UID0_ANOMALY" "Non-root UID 0 users: $uid0" "Remove or change UID for: $uid0"
    else
        pass "UID0_CLEAN" "Only root has UID 0" ""
    fi
    # Empty passwords
    local empty_pw
    empty_pw=$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null | head -5 || true)
    if [ -n "$empty_pw" ]; then
        crit "EMPTY_PASSWORD" "Users with empty/no password: $empty_pw" "Set password: passwd <user>"
    else
        pass "PASSWD_ALL_SET" "All users have passwords" ""
    fi
}

# ── CAT_B: CVE & Packages ──

check_trivy() {
    CATEGORY="cve_vulnerabilities"
    if ! command -v trivy &>/dev/null; then
        warn "TRIVY_NOT_FOUND" "trivy not installed, cannot scan CVEs" "Install trivy for CVE scanning"
        return
    fi
    local outfile
    outfile=$(mktemp /tmp/trivy-XXXXXX.json)
    echo "  [*] Running trivy filesystem scan (this may take several minutes)..."
    trivy fs / \
        --scanners vuln \
        --severity CRITICAL,HIGH \
        --format json \
        --quiet \
        --no-progress \
        --ignore-unfixed \
        --timeout 10m \
        -o "$outfile" 2>/dev/null || true
    if [ -s "$outfile" ]; then
        python3 -c "
import json, sys
try:
    with open('$outfile') as f:
        data = json.load(f)
    results = data.get('Results', [])
    all_vulns = []
    for r in results:
        for v in r.get('Vulnerabilities', []):
            all_vulns.append(v)
    crit_count = len([v for v in all_vulns if v.get('Severity') == 'CRITICAL'])
    high_count = len([v for v in all_vulns if v.get('Severity') == 'HIGH'])
    print(f'{crit_count},{high_count}')
    for v in all_vulns[:10]:
        pkg = v.get('PkgName', '?')
        sev = v.get('Severity', '?')
        vid = v.get('VulnerabilityID', '?')
        title = v.get('Title', '?')[:80]
        print(f'{sev}|{vid}|{pkg}|{title}')
except Exception as e:
    print(f'0,0')
    print(f'PARSE_ERROR: {e}')
" > /tmp/trivy-summary.txt 2>/dev/null || echo "0,0" > /tmp/trivy-summary.txt
        local summary
        summary=$(head -1 /tmp/trivy-summary.txt)
        local crit_count high_count
        crit_count=$(echo "$summary" | cut -d, -f1)
        high_count=$(echo "$summary" | cut -d, -f2)
        if [ "$crit_count" -gt 0 ] || [ "$high_count" -gt 5 ]; then
            crit "TRIVY_CRITICAL_VULNS" "Critical: $crit_count  High: $high_count" "Run 'trivy fs /' for full report and patch CVEs"
        elif [ "$high_count" -gt 0 ]; then
            fail "TRIVY_HIGH_VULNS" "High: $high_count" "Patch high-severity CVEs"
        else
            pass "TRIVY_CLEAN" "No critical/high CVEs found" ""
        fi
        # Also extract top 10 for findings list
        tail -n +2 /tmp/trivy-summary.txt | while IFS='|' read -r sev vid pkg title; do
            if [ -n "$sev" ]; then
                log_finding "$([ "$sev" = "CRITICAL" ] && echo "critical" || echo "high")" "TRIVY_$vid" "$pkg: $title" 4 "$vid" "Update package: $pkg"
            fi
        done
    fi
    rm -f "$outfile" /tmp/trivy-summary.txt
}

check_outdated_kernel() {
    CATEGORY="cve_vulnerabilities"
    local current_kernel
    current_kernel=$(uname -r)
    local latest_kernel
    latest_kernel=$(rpm -q kernel-core --last 2>/dev/null | head -1 | sed 's/kernel-core-//' | awk '{print $1}' || echo "")
    if [ -n "$latest_kernel" ] && [ "$current_kernel" != "$latest_kernel" ]; then
        warn "OUTDATED_KERNEL" "Running kernel: $current_kernel (latest installed: $latest_kernel)" "Reboot to use latest kernel"
    else
        pass "KERNEL_CURRENT" "Running latest kernel: $current_kernel" ""
    fi
}

# ── CAT_C: Network Security ──

check_listening_ports() {
    CATEGORY="network_security"
    local known_ports="22 80 443 8443 3306 5432 6379 9200 9300 5044 1514 1515 55000"
    local unknown=""
    if command -v ss &>/dev/null; then
        while IFS=' ' read -r port; do
            [ -z "$port" ] && continue
            if ! echo "$known_ports" | grep -qF "$port"; then
                unknown="$unknown $port"
            fi
        done < <(ss -tlnp4 2>/dev/null | awk 'NR>1{print $4}' | grep -oP ':\K\d+' | sort -u)
    fi
    if [ -n "$unknown" ]; then
        fail "UNEXPECTED_PORTS" "Unexpected listening ports:$unknown" "Check services on these ports and close if unnecessary"
    else
        pass "PORTS_CLEAN" "No unexpected listening ports" ""
    fi
}

check_firewall() {
    CATEGORY="network_security"
    if command -v firewall-cmd &>/dev/null; then
        local default_zone
        default_zone=$(firewall-cmd --get-default-zone 2>/dev/null)
        if [ "$default_zone" == "drop" ] || [ "$default_zone" == "block" ]; then
            pass "FIREWALL_DEFAULT_DENY" "Firewall default zone: $default_zone" ""
        else
            fail "FIREWALL_OPEN" "Firewall default zone: $default_zone (expected: drop/block)" "firewall-cmd --set-default-zone=drop"
        fi
    elif command -v iptables &>/dev/null; then
        local policy
        policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' || echo "")
        if echo "$policy" | grep -qi "drop\|deny"; then
            pass "IPTABLES_POLICY" "iptables INPUT policy: $policy" ""
        else
            fail "IPTABLES_POLICY" "iptables INPUT policy: $policy (expected: DROP)" "iptables -P INPUT DROP"
        fi
    else
        warn "NO_FIREWALL" "No firewall detected" "Install firewalld or iptables"
    fi
}

check_insecure_services() {
    CATEGORY="network_security"
    for svc in telnet ftp rsh rlogin rexec; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            fail "INSECURE_SVC_$(echo "$svc" | tr 'a-z' 'A-Z')" "Insecure service running: $svc" "Replace with SSH/ SFTP"
        fi
    done
    pass "INSECURE_SERVICES" "No insecure legacy services running" ""
}

# ── CAT_D: Container & Application Security ──

check_docker() {
    CATEGORY="container_security"
    if ! command -v docker &>/dev/null; then
        pass "DOCKER_NOT_INSTALLED" "Docker not installed" ""
        return
    fi
    # Check if Docker daemon is running
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        warn "DOCKER_NOT_RUNNING" "Docker installed but not running" ""
        return
    fi
    # Privileged containers
    local priv
    priv=$(docker ps --quiet --all 2>/dev/null | xargs -I{} docker inspect {} --format '{{.Name}} {{.HostConfig.Privileged}}' 2>/dev/null | grep true | awk '{print $1}' || true)
    if [ -n "$priv" ]; then
        crit "DOCKER_PRIVILEGED" "Privileged containers: $priv" "Remove --privileged flag"
    fi
    # Host network mode
    local hostnet
    hostnet=$(docker ps --quiet 2>/dev/null | xargs -I{} docker inspect {} --format '{{.Name}} {{.HostConfig.NetworkMode}}' 2>/dev/null | grep host | awk '{print $1}' || true)
    if [ -n "$hostnet" ]; then
        fail "DOCKER_HOST_NETWORK" "Host network mode containers: $hostnet" "Use bridge network instead"
    fi
    # User namespace remap
    local userns
    userns=$(docker info 2>/dev/null | grep "Userns" | awk '{print $2}' || echo "disabled")
    if [ "$userns" == "disabled" ]; then
        warn "DOCKER_USERNS" "User namespace remap: disabled" "Enable: --userns-remap=default in /etc/docker/daemon.json"
    else
        pass "DOCKER_USERNS" "User namespace remap: enabled" ""
    fi
}

check_k8s() {
    CATEGORY="container_security"
    if ! command -v kubectl &>/dev/null; then
        return  # not a k8s node
    fi
    # Check for privileged pods
    local priv_pods
    priv_pods=$(kubectl get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for item in data.get('items', []):
        ns = item['metadata']['namespace']
        name = item['metadata']['name']
        for c in item.get('spec', {}).get('containers', []):
            if c.get('securityContext', {}).get('privileged', False):
                print(f'{ns}/{name}')
except: pass
" 2>/dev/null || true)
    if [ -n "$priv_pods" ]; then
        crit "K8S_PRIVILEGED" "Privileged pods: $(echo "$priv_pods" | tr '\n' ' ')" "Remove securityContext.privileged"
    fi
}

# ── CAT_E: Advanced Threats ──

check_rootkit() {
    CATEGORY="advanced_threats"
    local indicators=0
    # Check for hidden processes (/proc)
    local ps_count proc_count
    if command -v ps &>/dev/null && [ -d /proc ]; then
        ps_count=$(ps aux 2>/dev/null | wc -l)
        proc_count=$(ls /proc/ | grep -E '^[0-9]+$' | wc -l)
        local diff=$(( proc_count - ps_count ))
        if [ "$diff" -gt 5 ]; then
            crit "HIDDEN_PROCESS" "Possible hidden processes: /proc has $proc_count entries, ps shows $ps_count" "Check with: ps aux | grep -v '\['
'"
            indicators=1
        fi
    fi
    # Check LD_PRELOAD
    if [ -n "${LD_PRELOAD:-}" ]; then
        fail "LD_PRELOAD_SET" "LD_PRELOAD is set: $LD_PRELOAD" "Unset LD_PRELOAD unless absolutely necessary"
        indicators=1
    fi
    # Check kernel module anomalies
    local known_clean=""
    local mods
    mods=$(lsmod 2>/dev/null | tail -n +2 | awk '{print $1}' | sort)
    local suspicious=""
    for m in $mods; do
        case "$m" in
            *hide*|*rootkit*|*sneaky*|*kbeast*|*adore*) suspicious="$suspicious $m" ;;
        esac
    done
    if [ -n "$suspicious" ]; then
        crit "SUSPICIOUS_MODULE" "Suspicious kernel modules:$suspicious" "Check: modinfo $suspicious"
        indicators=1
    fi
    # Check /etc/ld.so.preload
    if [ -f /etc/ld.so.preload ] && [ -s /etc/ld.so.preload ]; then
        fail "LD_PRELOAD_FILE" "/etc/ld.so.preload exists and is not empty" "Check contents and remove if unauthorized"
        indicators=1
    fi
    if [ "$indicators" -eq 0 ]; then
        pass "ROOTKIT_CLEAN" "No rootkit indicators found" ""
    fi
    echo "$indicators" > /tmp/rootkit_indicator.txt
}

check_cron_anomalies() {
    CATEGORY="advanced_threats"
    local cron_files
    cron_files=$(mktemp)
    find /var/spool/cron /etc/cron* /etc/anacrontab -type f 2>/dev/null > "$cron_files"
    local suspicious=0
    while IFS= read -r f; do
        if grep -qE 'curl|wget|bash -c|base64' "$f" 2>/dev/null; then
            warn "CRON_SUSPICIOUS" "Suspicious cron entry in $f" "Verify the cron job"
            suspicious=1
        fi
    done < "$cron_files"
    if [ "$suspicious" -eq 0 ]; then
        pass "CRON_CLEAN" "No suspicious cron entries" ""
    fi
    rm -f "$cron_files"
}

# ── Write findings to JSON file ──

write_findings_json() {
    local output_file="$1"
    local hostname="$2"
    local tier="$3"
    local overall_risk="${4:-0}"
    local severity="${5:-unknown}"

    local json
    json=$(python3 /usr/local/bin/risk-score-engine.py \
        --findings <(printf '%s\n' "${FINDINGS[@]}") \
        --hostname "$hostname" \
        --tier "$tier" \
        --overall-risk "$overall_risk" \
        --severity "$severity")
    echo "$json" > "$output_file"
    echo "  [*] Risk score written to: $output_file"
    echo "  [*] Overall risk: $overall_risk ($severity)"
    echo "  [*] Total findings: ${#FINDINGS[@]}"
}
