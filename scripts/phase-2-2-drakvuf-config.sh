#!/bin/bash
# Phase 2.2: DRAKVUF Configuration + systemd Service
set -euo pipefail

DRAKVUF_BIN="/usr/local/bin/drakvuf"

echo "[*] Phase 2.2: DRAKVUF Configuration"
echo "========================================"

# Main inspector config (minimal syscall whitelist)
cat > /etc/drakvuf/inspector.json << 'CFG'
{
    "inject_jitter": true,
    "jitter_min_us": 50,
    "jitter_max_us": 500,
    "memory_access_monitoring": {
        "enabled": true,
        "mode": "sampling",
        "sample_interval_ms": 5000,
        "sample_duration_ms": 100,
        "sample_regions": ["kernel_text", "module_text", "process_text"]
    },
    "syscalls": [
        "execve", "execveat", "fork", "clone", "clone3",
        "init_module", "finit_module", "delete_module",
        "connect", "bind", "socket",
        "ptrace", "process_vm_writev", "process_vm_readv",
        "open", "creat", "unlink", "rename", "write"
    ],
    "strategy": "whitelist",
    "default_action": "pass"
}
CFG

cat > /etc/drakvuf/syscall-whitelist.json << 'WLCFG'
{
    "syscalls": [
        "execve", "execveat", "fork", "clone", "clone3",
        "init_module", "finit_module", "delete_module",
        "connect", "bind", "socket",
        "ptrace", "process_vm_writev", "process_vm_readv",
        "open", "creat", "unlink", "rename", "write"
    ],
    "strategy": "whitelist",
    "default_action": "pass"
}
WLCFG

cat > /etc/drakvuf/jitter.json << 'JCFG'
{
    "inject_jitter": true,
    "jitter_min_us": 50,
    "jitter_max_us": 500,
    "jitter_distribution": "uniform"
}
JCFG

cat > /etc/drakvuf/memory-policy.json << 'MCFG'
{
    "memory_access_monitoring": {
        "enabled": true,
        "mode": "sampling",
        "sample_interval_ms": 5000,
        "sample_duration_ms": 100,
        "sample_regions": ["kernel_text", "module_text", "process_text"]
    }
}
MCFG

# systemd service template (one per VM)
cat > /etc/systemd/system/drakvuf@.service << 'SVC'
[Unit]
Description=DRAKVUF Introspection for %I
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/drakvuf \
    -r %I \
    -i /etc/drakvuf/inspector.json \
    -k /var/lib/drakvuf/symbols/%I/system.map \
    --json-file /var/log/drakvuf/%I.json \
    --json-stats /var/log/drakvuf/%I-stats.json \
    --reconnect 60 \
    --timeout 0
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
MemoryMax=4G
MemorySwapMax=1G
CPUQuota=50%

[Install]
WantedBy=multi-user.target
SVC

# DRAKVUF watchdog service
cat > /etc/systemd/system/drakvuf-watchdog.service << 'WDSVC'
[Unit]
Description=DRAKVUF Process Watchdog
After=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/drakvuf-watchdog.sh
Restart=always
RestartSec=10
StartLimitInterval=300
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
WDSVC

# Watchdog script
cat > /usr/local/bin/drakvuf-watchdog.sh << 'WD'
#!/bin/bash
set -euo pipefail

logger -t drakvuf-watchdog "Watchdog started"

while true; do
    for GUEST in $(virsh list --name 2>/dev/null || echo ""); do
        [ -z "$GUEST" ] && continue

        PID=$(pgrep -f "drakvuf.*-r ${GUEST}" | head -1)
        if [ -z "$PID" ]; then
            logger -t drakvuf-watchdog "WARN: DRAKVUF not running for ${GUEST}, restarting"
            systemctl restart "drakvuf@${GUEST}" 2>/dev/null || true
            continue
        fi

        # Check JSON output freshness
        JSON_FILE="/var/log/drakvuf/${GUEST}.json"
        if [ -f "$JSON_FILE" ]; then
            LAST_MOD=$(stat -c %Y "$JSON_FILE" 2>/dev/null || echo 0)
            NOW=$(date +%s)
            DIFF=$((NOW - LAST_MOD))
            if [ $DIFF -gt 300 ]; then
                logger -t drakvuf-watchdog "WARN: No output from ${GUEST} for ${DIFF}s, restarting"
                kill -TERM "$PID" 2>/dev/null || true
                sleep 3
                systemctl restart "drakvuf@${GUEST}" 2>/dev/null || true
            fi
        fi
    done
    sleep 60
done
WD
chmod +x /usr/local/bin/drakvuf-watchdog.sh

systemctl daemon-reload
echo "[+] DRAKVUF configuration complete"
echo "    Start: systemctl start drakvuf@<vm-name>"
echo "    Start: systemctl start drakvuf-watchdog"
