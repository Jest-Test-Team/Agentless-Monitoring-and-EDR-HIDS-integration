# Tier-Based Monitoring Strategy

根據業務等級與資料機敏性，將監控對象分為四個層級，每層使用不同的監控技術組合。

---

## 分層總覽

```
┌─────────────────────────────────────────────────────────────────┐
│  Tier 0: PRD / 機敏資料                                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  DRAKVUF (VMI)  │  NIDS (Suricata)  │  Host Wazuh       │   │
│  │  ─────────────  │  ───────────────  │  ───────────       │   │
│  │  syscall hook   │  TLS fingerprint  │  Host hardening    │   │
│  │  memory scan    │  DNS decode       │  Auditd rules      │   │
│  │  process track  │  SMB decode       │  Filebeat outbound │   │
│  │  零 Agent       │  port mirror      │  BMC/IPMI monitor  │   │
│  └──────────────────────────────────────────────────────────┘   │
│  流量規模: ~50-500 GB/day per VM                                 │
├─────────────────────────────────────────────────────────────────┤
│  Tier 1: 一般內部服務 VM                                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Wazuh Agent  │  Osquery  │  Auditd                     │   │
│  │  ───────────  │  ───────  │  ──────                     │   │
│  │  File/Reg     │  SQL      │  audit rules                │   │
│  │  Process      │  live     │  syscall filter             │   │
│  │  Network      │  query    │  immutable config            │   │
│  └──────────────────────────────────────────────────────────┘   │
│  流量規模: ~5-20 GB/day per VM                                   │
├─────────────────────────────────────────────────────────────────┤
│  Tier 2: Bare Metal / 實體主機                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Wazuh Agent  │  Osquery  │  Auditd  │  Sysmon (Win)    │   │
│  │  + FW rules   │  + Rootkit │  + File  │  + Process tree  │   │
│  │               │   detect   │   integrity                 │   │
│  └──────────────────────────────────────────────────────────┘   │
│  流量規模: ~10-30 GB/day per host                                 │
├─────────────────────────────────────────────────────────────────┤
│  Tier 3: Dev / Test / 非生產                                     │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Wazuh Agent (low-cost)  │  Syslog-only                  │   │
│  │  ───────────────────────  │  ──────────                   │   │
│  │  只收 critical alert    │  不收 VMI / Osquery           │   │
│  └──────────────────────────────────────────────────────────┘   │
│  流量規模: ~1-5 GB/day per host                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tier 0: PRD / 機敏資料 (No Agent)

### 目標
對不能安裝 Agent 的機敏業務 VM，提供完整的 **Kernel + Network + Host** 三層監控，且不侵入 Guest OS。

### 技術棧

| 層級 | 技術 | 負責偵測 |
|------|------|----------|
| Kernel | DRAKVUF + LibVMI | Process creation, syscall hook, module load, memory injection |
| Network | Suricata (port mirror) + Zeek | C2 beacon, DNS tunneling, SMB lateral movement, TLS fingerprint |
| Host (Dom0) | Wazuh Agent + Auditd + Osquery | Host intrusion, kernel module rootkit, config tampering |

### 系統呼叫最小 hook 清單

```json
{
    "syscalls": [
        "execve", "execveat", "fork", "clone",
        "init_module", "finit_module", "delete_module",
        "connect", "bind", "socket",
        "ptrace", "process_vm_writev", "process_vm_readv",
        "open", "creat", "unlink", "rename", "write"
    ],
    "strategy": "whitelist",
    "default_action": "pass"
}
```

### NIDS 整合架構

```
Tier 0 VM ──→ vSwitch ──→ Port Mirror ──→ Suricata (bond0.100)
                                         │
                                    eve.json
                                         │
                                    Filebeat ──→ Logstash ──→ OpenSearch
                                         │
DRAKVUF ──→ output.json ──→ Filebeat ──┘
```

### 部署限制
- Guest OS Kernel 必須凍結（versionlocked），不自動更新
- Host 必須為 Intel Xeon (Skylake+)，啟用 Altp2m/EPT
- 不支援 Live Migration（VM pinned to Host）
- 需要至少 2 台 Host 做 Active/Standby HA

---

## Tier 1: 一般內部服務 VM

### 目標
對可接受輕量 Agent 的內部服務 VM，提供標準 EDR/HIDS 監控。

### 技術棧

| 元件 | 配置 |
|------|------|
| Wazuh Agent | 啟用 FIM (File Integrity Monitoring), Process Monitoring, Network Monitoring |
| Osquery | 排程查詢（每 60s）：listening ports, running processes, crontab, authorized_keys |
| Auditd | 監控：`-w /etc/passwd -p wa`, `-w /etc/shadow -p wa`, `-a always,exit -S execve` |

### Wazuh Agent 最小配置

```xml
<ossec_config>
  <syscheck>
    <frequency>7200</frequency>
    <directories check_all="yes">/etc,/usr/bin,/usr/sbin,/bin,/sbin</directories>
    <directories check_all="yes" realtime="yes">/etc/ssh</directories>
    <ignore>/etc/mtab</ignore>
  </syscheck>
  <rootcheck>
    <frequency>3600</frequency>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
  </rootcheck>
  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>
</ossec_config>
```

---

## Tier 2: Bare Metal / 實體主機

### 目標
對不可虛擬化（或不需要虛擬化）的實體主機提供完整的 HIDS 保護。

### 技術棧

| 元件 | Windows | Linux |
|------|---------|-------|
| HIDS Agent | Wazuh Agent | Wazuh Agent |
| Syscall Audit | Sysmon | Auditd |
| Live Query | Osquery (Windows) | Osquery |
| File Integrity | Wazuh FIM | Wazuh FIM + AIDE |
| Network | Windows FW log | nftables log |

### Sysmon + Wazuh 聯合配置 (Windows)

```xml
<ruleset>
  <rule id="100001" level="7">
    <if_group>windows_sysmon</if_group>
    <field name="win.eventdata.eventID">1</field>
    <description>Process created: $(win.eventdata.image)</description>
  </rule>
  <rule id="100002" level="5">
    <if_group>windows_sysmon</if_group>
    <field name="win.eventdata.eventID">3</field>
    <description>Network connection: $(win.eventdata.destinationIp):$(win.eventdata.destinationPort)</description>
  </rule>
</ruleset>
```

### Auditd + Osquery + Wazuh 聯合配置 (Linux)

```bash
cat > /etc/osquery/osquery.conf << 'OSQ'
{
  "schedule": {
    "kernel_modules": {
      "query": "SELECT name, size, used_by, status FROM kernel_modules;",
      "interval": 300
    },
    "listening_ports": {
      "query": "SELECT pid, port, protocol, address FROM listening_ports;",
      "interval": 60
    },
    "process_events": {
      "query": "SELECT pid, path, cmdline, time FROM process_events;",
      "interval": 120
    },
    "suid_binaries": {
      "query": "SELECT path FROM suid_binaries;",
      "interval": 86400
    },
    "arp_cache": {
      "query": "SELECT address, mac, interface FROM arp_cache;",
      "interval": 300
    }
  },
  "file_paths": {
    "system_binaries": ["/usr/bin/%%", "/usr/sbin/%%"],
    "etc": ["/etc/%%"]
  }
}
OSQ
```

---

## Tier 3: Dev / Test / 非生產

### 目標
最低成本的基礎監控，確保開發環境的安全基線。

### 技術棧

| 元件 | 配置 |
|------|------|
| Wazuh Agent | 僅啟用 critical rules（rootkit 檢測、惡意 IP 連線） |
| Log Shipping | Rsyslog 直接送 syslog 到 Logstash（不經過 Wazuh Manager） |
| 保存策略 | 日誌保留 30 天（vs Tier 0 的 365 天） |

### Rsyslog 直接輸出配置

```bash
cat > /etc/rsyslog.d/90-logstash.conf << 'RSYS'
*.* @logstash-tier3.example.com:5514
RSYS
```

---

## Cross-Tier 關聯查詢範例 (OpenSearch)

```json
// 場景：Tier 0 VM 的 DRAKVUF 檢測到 process_injection
// 同時 Tier 1 的 Admin VM 有異常 RDP 連線
GET security-events-*/_search
{
  "query": {
    "bool": {
      "filter": [
        { "term": { "event.category": "process" } },
        { "term": { "event.action": "process-created" } },
        { "term": { "process.executable": "powershell.exe" } }
      ],
      "must_not": [
        { "term": { "labels.tier": "tier3" } }
      ],
      "should": [
        { "term": { "source.ip": "192.168.1.100" } }
      ],
      "minimum_should_match": 1
    }
  },
  "sort": [ { "@timestamp": "desc" } ]
}
```
