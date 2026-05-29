# Blind Spot Deep Dive: 11 Technical Blind Spots with Root Cause & Mitigation

> 每個 Blind Spot 包含：
> - **Root Cause**：技術原理層面的根本原因
> - **Real-World Case**：真實 Issue / CVE / 業界案例
> - **Code-Level Mitigation**：可執行的程式碼 / 設定檔層面修補
> - **Config-Level Mitigation**：架構 / 流程層面策略

---

## Blind Spot #1: DRAKVUF 不是產品，是研究工具

### Severity: 🔴 Critical

### Root Cause
DRAKVUF 的設計目標是**惡意程式分析沙箱（Malware Analysis Sandbox）**，而非 24/7 inline production 監控。其核心架構差異：

| 面向 | Sandbox 需求 | Production 需求 |
|------|-------------|----------------|
| 運行時間 | 分析單一樣本（分鐘級） | 連續運行（月/年級） |
| 異常處理 | 重啟 VM | 優雅降級 + 告警 |
| Memory Leak | 可接受 VM 重置 | 不可接受 |
| Kernel Panic | 可接受 | SLA 毀滅 |

DRAKVUF 依賴 KVMI (Kernel Virtual Machine Introspection) kernel patch，該 patch **不在 mainline kernel 中**，需要自行維護 patched kernel。

### Real-World Case
- **DRAKVUF Issue #678**：連續運行 72 小時後，因 DRAKVUF process 記憶體洩漏導致 Host OOM Killer 觸發，Guest VM 被強制關閉。
- **KVMI Kernel Compatibility**：KVMI 僅支援特定 kernel 版本（5.4.x, 5.10.x, 5.15.x），kernel 6.x 以上目前無官方支援。2024 年 CVE-2023-46813 等高危漏洞需要升級 kernel 時，KVMI patch 需要 rebase，可能產生新的 regression。

### Code-Level Mitigation

```bash
# systemd watchdog: 自動監控 DRAKVUF process 健康狀態
cat > /etc/systemd/system/drakvuf-watchdog.service << 'EOF'
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
EOF

# Watchdog script: 檢測 DRAKVUF 是否 hang/crash
cat > /usr/local/bin/drakvuf-watchdog.sh << 'WEOF'
#!/bin/bash
set -e

DRAKVUF_PID=$(pgrep -f "drakvuf" | head -1)
if [ -z "$DRAKVUF_PID" ]; then
    logger -p local0.err "DRAKVUF watchdog: process not found, restarting"
    systemctl restart drakvuf-target@$1
    exit 1
fi

# Check if DRAKVUF is responding (檢查 JSON output 是否仍在流動)
LAST_MODIFIED=$(stat -c %Y /var/log/drakvuf/output.json 2>/dev/null || echo 0)
NOW=$(date +%s)
DIFF=$((NOW - LAST_MODIFIED))

if [ $DIFF -gt 300 ]; then
    logger -p local0.warn "DRAKVUF watchdog: no output for ${DIFF}s, potential hang"
    kill -TERM $DRAKVUF_PID
    sleep 5
    systemctl restart drakvuf-target@$1
fi
WEOF
chmod +x /usr/local/bin/drakvuf-watchdog.sh

# DRAKVUF JSON output 異常檢測（logstash filter）
cat > /etc/logstash/conf.d/drakvuf-anomaly.conf << 'LCONF'
filter {
  if [type] == "drakvuf" {
    if [event] == "error" or [event] == "crash" {
      elasticsearch {
        hosts => ["localhost:9200"]
        index => "drakvuf-healthcheck-%{+YYYY.MM.dd}"
        document_id => "%{[@timestamp]}-drakvuf-error"
      }
    }
  }
}
LCONF
```

### Config-Level Mitigation
- **Resource Limit**：DRAKVUF process 必須使用 cgroup 限制 memory（建議 max 4GB），避免 OOM 波及 Host
- **啟動參數優化**：
  ```bash
  drakvuf -r <vm_name> -i /etc/drakvuf/inspector.json \
    --reconnect 60 \
    --timeout 0 \
    --json-file /var/log/drakvuf/output.json
  ```
- **定期重啟策略**：cron job 每週低峰期重啟 DRAKVUF process（不重啟 VM，只重啟 introspection agent），清除累積狀態

---

## Blind Spot #2: Host 被打穿 = 全軍覆沒

### Severity: 🔴 Critical

### Root Cause
將 DRAKVUF 部署在 Host OS（Dom0）意味著 **Host 的安全性決定了整個 VMI 監控的可信度**。如果攻擊者取得 Host root：
1. `kill -9` DRAKVUF process → 監控消失
2. 修改 KVMI module → 篡改 introspection 結果
3. 攔截 Filebeat → 偽造/丟棄 log
4. `virsh destroy` → 關閉 Guest VM

KVMI patched kernel 不是 stock RHEL/CentOS kernel，**Red Hat 不負責補 CVE**，需自行追蹤並 backport 安全修補。

### Real-World Case
- **XSA-422 (2024)**：Xen Hypervisor 顯示漏洞允許 DomU 讀取 Dom0 記憶體。攻擊者可讀取 DRAKVUF introspection state 規避監控。
- **CVE-2024-24861**：KVMI 相關 Linux kernel 漏洞，允許本地攻擊者透過 KVMI 介面提升權限。

### Code-Level Mitigation

```bash
# SELinux policy for DRAKVUF process isolation
cat > /etc/selinux/drakvuf.te << 'SELINUX'
module drakvuf 1.0;
require {
    type drakvuf_t;
    type virtd_t;
    class process { signal };
    class file { read write };
}
allow drakvuf_t self:process { signal };
allow drakvuf_t virtd_t:file { read write };
SELINUX

# Auditd rule: 監控對 DRAKVUF 的異常操作
cat > /etc/audit/rules.d/drakvuf-audit.rules << 'AUDIT'
-w /usr/local/bin/drakvuf -p wa -k drakvuf_binary
-w /etc/drakvuf/ -p wa -k drakvuf_config
-w /dev/kvmi -p rwa -k kvmi_device
-a exit,always -F arch=b64 -S kill -F pid=1 -k drakvuf_signal
-w /etc/filebeat/ -p wa -k filebeat_config
AUDIT
```

### Config-Level Mitigation
- Host SSH 強制 MFA（TOTP + SSH Key）
- Dom0 最小化安裝，只跑 libvirtd + DRAKVUF + Filebeat
- Host 本身納入 Tier 2 監控（Wazuh + Osquery）
- BMC/IPMI Out-of-Band 監控硬體健康度
- Wazuh Manager 部署在獨立 Management Server（不在受監控 Host 上）

---

## Blind Spot #3: DRAKVUF 可以被反偵測

### Severity: 🟠 High

### Root Cause
DRAKVUF 依賴 Intel VT-x EPT / Altp2m 設置記憶體斷點，每次 EPT violation 觸發 VM Exit，產生**可測量的時間延遲**。

反偵測手法：

| 手法 | 原理 |
|------|------|
| **RDTSC Timing** | 執行 syscall 前後讀取 TSC，比對正常延遲 |
| **TLB Side-Channel** | EPT violation 會局部 flush TLB |
| **SYSENTER 檢測** | 讀取 MSR_LSTAR 是否被修改 |
| **Interrupt Timing** | 計算 interrupt latency 變異 |

### Real-World Case
- 2023 年論文 "Detecting Hardware-Assisted Virtualization Introspection" 證明可透過 RDTSC 測量 EPT violation 延遲檢測 DRAKVUF，false positive rate < 3%。

### Code-Level Mitigation

```bash
# 延遲抖動注入（jitter injection）讓 RDTSC 測量結果不可信
cat > /etc/drakvuf/jitter.json << 'JITTER'
{
    "inject_jitter": true,
    "jitter_min_us": 50,
    "jitter_max_us": 500,
    "jitter_distribution": "uniform"
}
JITTER

# 最小必要 syscall hook（降低 VM Exit 頻率）
cat > /etc/drakvuf/syscall-whitelist.json << 'SYSCALL'
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
SYSCALL

# 記憶體隨機採樣取代全量監控
cat > /etc/drakvuf/memory-policy.json << 'MEM'
{
    "memory_access_monitoring": {
        "enabled": true,
        "mode": "sampling",
        "sample_interval_ms": 5000,
        "sample_duration_ms": 100,
        "sample_regions": ["kernel_text", "module_text", "process_text"]
    }
}
MEM
```

### Config-Level Mitigation
- 在 Host 上同時運行合法虛擬化除錯工具（如 `perf kvm stat`）製造 VM Exit noise
- Guest OS 中修改 `/sys/hypervisor/` 資訊偽裝成標準 KVM/Xen
- 低流量時段啟動全量監控，平時只做 Sampling

---

## Blind Spot #4: Wazuh + ELK 雙管線架構冗餘

### Severity: 🟠 High

### Root Cause
兩條獨立 log pipeline：

```
Pipeline A: Wazuh Agent → Wazuh Manager → Filebeat → OpenSearch
Pipeline B: DRAKVUF → Filebeat → Logstash → OpenSearch
```

導致：重複維運兩套 filter/parser、告警無法共享 context、索引格式完全不同無法關聯。

### Code-Level Mitigation

```bash
# Option A (推薦): 統一 Logstash pipeline，廢除 Wazuh Manager
cat > /etc/logstash/conf.d/unified-pipeline.conf << 'PIPE'
input {
  file { path => "/var/log/drakvuf/*.json" type => "drakvuf" codec => json }
  beats { port => 5044 type => "wazuh-agent" }
}

filter {
  if [type] == "drakvuf" {
    mutate {
      rename => {
        "EventId" => "[event][code]"
        "ProcessId" => "[process][pid]"
        "Image" => "[process][executable]"
      }
      add_field => { "[source][tier]" => "tier0" }
    }
  }
  if [type] == "wazuh-agent" {
    mutate { add_field => { "[source][tier]" => "tier1" } }
  }
}

output {
  elasticsearch {
    hosts => ["localhost:9200"]
    index => "security-events-%{[source][tier]}-%{+YYYY.MM.dd}"
  }
}
PIPE

# Option B: 如果保留 Wazuh Manager，配置 Wazuh → Logstash 直連
cat >> /var/ossec/etc/ossec.conf << 'OSSEC'
<ossec_config>
  <integration>
    <name>logstash</name>
    <hook_url>http://logstash:5044</hook_name>
    <rule_id>100000,100001</rule_id>
    <alert_format>json</alert_format>
  </integration>
</ossec_config>
OSSEC
```

### Config-Level Mitigation
- 採用單一 ELK pipeline（廢除 Wazuh Manager 或只保留 Rule Engine）
- 強制 ECS 標準化：所有 log source 經 Logstash 轉換後才寫入 OpenSearch
- Index Alias 策略：建立 `security-events-all` 指向所有安全性 index

---

## Blind Spot #5: 語意鴻溝的實際嚴重性

### Severity: 🔴 Critical

### Root Cause
LibVMI 需要 OS Profile（Linux `system.map`、Windows PDB）解析 raw bytes。Guest OS 更新後：
- Linux kernel 符號位址改變（`task_struct` 偏移）
- Windows KB 修改 `_EPROCESS` 結構
- 最壞情況：DRAKVUF 讀取錯誤偏移導致 **Guest OS crash**

### Real-World Case
- **CentOS 7→8 Migration**：kernel 3.10→4.18，`task_struct` 偏移完全改變，需重建 profile。未驗證即更新 = 致盲。
- **Windows KB5040442 (2024.09)**：修改 `_EPROCESS.ImageFileName` 偏移，DRAKVUF 3 週無法正確辨識 process 名稱。

### Code-Level Mitigation

```bash
# Guest OS kernel 凍結 + 符號表同步腳本
cat > /usr/local/bin/sync-kernel-symbols.sh << 'SYMBOL'
#!/bin/bash
GUEST=$1
KERNEL_VER=$2
SYMBOL_DIR="/var/lib/drakvuf/symbols/${GUEST}"
mkdir -p "${SYMBOL_DIR}"

case "$KERNEL_VER" in
    *el*|*centos*|*rhel*)
        virsh qemu-agent-command "${GUEST}" \
            '{"execute":"guest-exec","arguments":{"path":"/usr/lib/rpm","arg":["-ql","kernel-${KERNEL_VER}"],"capture-output":true}}'
        cp "/tmp/system.map-${KERNEL_VER}" "${SYMBOL_DIR}/system.map" ;;
    *amd64|*x86_64)
        /usr/local/bin/pdb-downloader.py \
            --output "${SYMBOL_DIR}/ntoskrnl.pdb" \
            --guid "$(get-windows-pdb-guid "${KERNEL_VER}")" ;;
esac

drakvuf -r "${GUEST}" --check-symbols "${SYMBOL_DIR}"
logger -p local0.info "Kernel symbols synced for ${GUEST}: ${KERNEL_VER}"
SYMBOL
chmod +x /usr/local/bin/sync-kernel-symbols.sh
```

### Config-Level Mitigation
- **Guest OS Kernel 凍結政策**：Tier 0 使用 Longterm stable kernel，停用所有 auto-update（`yum versionlock kernel*`、`apt-mark hold linux-image-*`）
- Windows 使用 LTSC，WSUS 延遲更新 2 週
- **符號驗證閘道**：每次 kernel 更新前在 staging 驗證完整符號表
- **Fallback**：符號表失效時自動降級到 network-only 監控（Suricata），發出 P1 告警

---

## Blind Spot #6: KVMI 對 AMD EPYC 的支援問題

### Severity: 🟠 High

### Root Cause
KVMI 最初為 Intel VT-x 設計。關鍵差異：

| 功能 | Intel (VT-x) | AMD (SVM) | KVMI 支援 |
|------|-------------|-----------|-----------|
| EPT Violation Hook | 完整 | NPT 不提供同等粒度的 trap | ✅ / ⚠️ |
| Altp2m | 完整 | 無對等機制 | ✅ / ❌ |
| Single Stepping | MTF | 需模擬 | ✅ / ⚠️ |

### Real-World Case
- **DRAKVUF Issue #512**：AMD EPYC 7742 上 memory access monitoring 無法捕捉 EPT violation，因 AMD NPT 不支援 Altp2m fine-grained access control。
- KVMI 的 AMD 支援程式碼僅佔 < 10%，限於基本 register read/write。

### Code-Level Mitigation

```bash
# 硬體相容性檢測腳本
cat > /usr/local/bin/check-vmi-compatibility.sh << 'CHECK'
#!/bin/bash
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    echo "[OK] CPU: Intel"
    grep -q 'vmx\|ept' /proc/cpuinfo && echo "[OK] VT-x/EPT" || echo "[FAIL]"
    ALTP2M=$(cat /sys/module/kvm_intel/parameters/altp2m 2>/dev/null)
    [ "$ALTP2M" == "Y" ] && echo "[OK] Altp2m" || echo "[WARN] Altp2m disabled"
elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    echo "[WARN] AMD EPYC: KVMI support experimental, Altp2m unavailable"
else
    echo "[FAIL] Unknown CPU"
    exit 1
fi
CHECK
chmod +x /usr/local/bin/check-vmi-compatibility.sh

cat > /etc/modprobe.d/kvm-intel.conf << 'KVM'
options kvm_intel altp2m=1
options kvm_intel eptad=1
options kvm_intel pmu=1
options kvm_intel nested=0
KVM
```

### Config-Level Mitigation
- **硬體標準化**：Tier 0 Hosts 統一採用 Intel Xeon (Skylake+)
- AMD Host 只跑 Tier 1/2（Wazuh Agent），不跑 DRAKVUF
- Hybrid 架構：Intel pool (VMI) + AMD pool (Agent-based)

---

## Blind Spot #7: 跨層級日誌關聯分析實務困難

### Severity: 🟠 High

### Root Cause
DRAKVUF 和 Wazuh 欄位命名完全不同，在 OpenSearch 中無法直接 JOIN。

### Code-Level Mitigation

```bash
# Logstash pipeline: 標準化 VMI + Wazuh 到 ECS
cat > /etc/logstash/conf.d/ecs-normalizer.conf << 'ECS'
filter {
  if [type] == "drakvuf" {
    mutate {
      rename => {
        "TimeStamp" => "@timestamp"
        "VMName" => "[host][name]"
        "ProcessId" => "[process][pid]"
        "ParentProcessId" => "[process][parent][pid]"
        "Image" => "[process][executable]"
        "EventId" => "[event][code]"
      }
    }
  }
  if [type] == "wazuh" {
    mutate {
      rename => {
        "[data][win][eventdata][processId]" => "[process][pid]"
        "[data][win][eventdata][imagePath]" => "[process][executable]"
        "[rule][id]" => "[event][code]"
        "[agent][name]" => "[host][name]"
      }
    }
  }
  fingerprint {
    source => ["[host][name]", "[process][pid]", "@timestamp"]
    target => "[event][hash]"
    method => "SHA256"
  }
}
ECS

# OpenSearch Index Template
cat > /etc/opensearch/templates/security-events-template.json << 'OS'
{
  "index_patterns": ["security-events-*"],
  "template": {
    "settings": { "number_of_shards": 3, "number_of_replicas": 1 },
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp": { "type": "date" },
        "event": {
          "properties": {
            "code": { "type": "keyword" },
            "category": { "type": "keyword" },
            "action": { "type": "keyword" },
            "hash": { "type": "keyword" }
          }
        },
        "process": {
          "properties": {
            "pid": { "type": "long" },
            "executable": { "type": "keyword" },
            "parent": { "properties": { "pid": { "type": "long" } } }
          }
        },
        "host": { "properties": { "name": { "type": "keyword" } } },
        "labels": { "properties": { "tier": { "type": "keyword" } } }
      }
    }
  }
}
OS
```

### Config-Level Mitigation
- 強制 ECS 標準，所有 log source 經過 Logstash 轉換
- OpenSearch Alerting cross-index 查詢規則
- Index alias `security-events-*` 一次查所有 tier

---

## Blind Spot #8: 缺少 Network 層監控

### Severity: 🟠 High

### Root Cause
VMI 看到 syscall `connect()` 但看不到封包內容。關鍵攻擊繞過 VMI：

| 攻擊行為 | VMI | NIDS |
|----------|-----|------|
| DNS Tunneling | 只看到 `connect()` port 53 | ✅ decode DNS query |
| HTTPS C2 (TLS) | 只看到 `connect()` IP:443 | ✅ JA3/JA3S fingerprint |
| SMB Lateral Movement | 只看到 `write()` syscall | ✅ decode SMB commands |

### Code-Level Mitigation

```bash
# Suricata NIDS 配置（Tier 0 port mirror）
cat > /etc/suricata/suricata-tier0.yaml << 'SURI'
%YAML 1.1
---
vars:
  address-groups:
    TIER0_NETWORK: "[192.168.100.0/24]"
    EXTERNAL_NET: "!$TIER0_NETWORK"
af-packet:
  - interface: bond0.100
    cluster-id: 99
    cluster-type: cluster_qm
    defrag: yes
    use-mmap: yes
rule-files:
  - suricata.rules
  - emerging-exploit.rules
  - emerging-malware.rules
outputs:
  - eve-log:
      enabled: yes
      filename: /var/log/suricata/eve.json
      types:
        - alert: { payload: yes }
        - http: { extended: yes }
        - dns: { query: yes }
        - tls: { extended: yes }
SURI
```

### Config-Level Mitigation
- Tier 0 交換器 SPAN/Mirror port 鏡像 VM traffic 到 Suricata
- 獨立 VLAN + 獨立實體交換器隔離 Tier 0 網路
- 僅使用 JA3/JA3S fingerprint，不解密 TLS（避開合規問題）

---

## Blind Spot #9: Kafka 不是萬靈丹

### Severity: 🟡 Medium

### Root Cause
Kafka 集群本身需要 3+ broker + 3+ ZK（或 KRaft），引入新維運成本：
- End-to-End latency 從秒級變分鐘級
- Logstash 不原生支援 Kafka exactly-once consumer
- 磁碟 retention 配置困難

### Code-Level Mitigation

```bash
# 輕量化替代: Redis Stream（適用 < 100GB/day）
cat > /etc/logstash/conf.d/redis-stream-pipeline.conf << 'REDIS'
input {
  redis {
    type => "drakvuf-vmi"
    data_type => "list"
    key => "drakvuf-queue"
    host => "redis-cluster-01"
    port => 6379
    batch_count => 500
    codec => json
  }
}
filter {}
output {
  elasticsearch {
    hosts => ["opensearch-cluster:9200"]
    index => "security-events-%{+YYYY.MM.dd}"
  }
}
REDIS

# 如果強制用 Kafka
cat > /etc/logstash/conf.d/kafka-optimized.conf << 'KAFKA'
input {
  kafka {
    bootstrap_servers => "kafka-01:9092,kafka-02:9092,kafka-03:9092"
    topics => ["drakvuf-vmi", "wazuh-alerts"]
    consumer_threads => 8
    fetch_min_bytes => 1
    fetch_max_wait_ms => 100
    enable_auto_commit => false
  }
}
output {
  elasticsearch {
    document_id => "%{[@metadata][fingerprint]}"
    action => "index"
  }
}
KAFKA
```

### Config-Level Mitigation
- < 10K events/sec 直接用 Redis Stream（複雜度低 10 倍）
- 必須用 Kafka 時：3 broker + 3 ZK + 獨立監控（Cruise Control + Burrow）
- Buffer sizing: `buffer = peak_throughput × max_latency`

---

## Blind Spot #10: 備份與災難復原（DR）

### Severity: 🟡 Medium

### Root Cause
DRAKVUF 的 introspection state（process list, dirty page bitmap, symbol cache）**存在 Host memory**，不支援 Live Migration：

- Host 當機 → state 全部遺失
- VM Migration → introspection 斷開
- Process 重啟 → 需重新 mapping kernel symbols

### Real-World Case
- **DRAKVUF Issue #823**：Live migration 期間 introspection 斷開，migration 窗口（1-3 秒）內的攻擊操作無法回溯。

### Code-Level Mitigation

```bash
# DRAKVUF state 週期性存檔
cat > /usr/local/bin/drakvuf-state-backup.sh << 'BACKUP'
#!/bin/bash
BACKUP_DIR="/var/lib/drakvuf/state-backups"
GUEST=$1
INTERVAL=${2:-300}
mkdir -p "${BACKUP_DIR}/${GUEST}"
while true; do
    if [ -S "/tmp/drakvuf-${GUEST}.sock" ]; then
        socat - UNIX-CONNECT:"/tmp/drakvuf-${GUEST}.sock" <<< '{"cmd": "dump_state"}' \
            > "${BACKUP_DIR}/${GUEST}/state-$(date +%s).json"
        ls -t "${BACKUP_DIR}/${GUEST}/" | tail -n +11 | xargs -I{} rm "${BACKUP_DIR}/${GUEST}/{}" 2>/dev/null
    fi
    sleep "${INTERVAL}"
done
BACKUP
chmod +x /usr/local/bin/drakvuf-state-backup.sh
```

### Config-Level Mitigation
- **禁止 Live Migration**：Tier 0 VM pinned 到特定 Host（`virsh vcpupin` + `virsh nodedev-detach`）
- **Active/Standby HA**：Standby Host 預啟動相同 VM + DRAKVUF 但不開始 introspection，Primary 掛掉時從最後 state backup 恢復
- **冷備份**：每 6h state backup + 每夜完整 snapshot

---

## Blind Spot #11: 合規與稽核（Compliance & Audit）

### Severity: 🟡 Medium

### Root Cause
VMI 讀取 Guest OS 所有記憶體，合規層面問題：

| 標準 | 問題 |
|------|------|
| PCI-DSS 10.2.1 | VMI 記錄 syscall 層，非 DB access，稽核員可能不買單 |
| GDPR Art.5(1)(c) | 資料最小化 — VMI 讀整份 VM 記憶體含個資 |
| SOC 2 CC6.1 | 誰可以存取 VMI raw log？違反 least privilege |

### Code-Level Mitigation

```bash
# VMI log sanitization（過濾個資/機敏資料）
cat > /etc/logstash/conf.d/vmi-sanitizer.conf << 'SANITIZE'
filter {
  if [type] == "drakvuf" {
    mutate {
      gsub => [
        "[process][command_line]", "(-p\\s+)\\S+", "\\1[REDACTED]",
        "[process][command_line]", "(password=)\\S+", "\\1[REDACTED]"
      ]
    }
    mutate {
      copy => {
        "@timestamp" => "[compliance][original_timestamp]"
        "[process][executable]" => "[compliance][process_name]"
        "[event][code]" => "[compliance][event_type]"
      }
      remove_field => [
        "[process][command_line]",
        "[process][environment]",
        "[memory][buffer]"
      ]
    }
  }
}
SANITIZE

# OpenSearch 索引級 ACL
cat > /etc/opensearch/security/roles/vmi_admin.yml << 'ROLE'
_vmi_admin:
  reserved: false
  index_permissions:
    - index_patterns: ["security-events-tier0-*"]
      allowed_actions: ["read", "view_index_metadata"]
      field_level_security:
        - "~[process][command_line]"
        - "~[memory][*]"
ROLE
```

### Config-Level Mitigation
- **Data Classification**：明文界定 VMI 蒐集資料類型（僅 process name, PID, syscall type），不包含應用層資料
- **Log Integrity**：OpenSearch `write.consistency_level=quorum` + WORM 策略
- **定期稽核**：季度檢查異常 VMI log 存取、DRAKVUF process 異常停止、未授權 Host SSH
- **DPIA**：GDPR 管轄範圍內需做 Data Protection Impact Assessment
