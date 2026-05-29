# Threat Model: Agentless VMI + EDR/HIDS + NIDS

> 使用 STRIDE 方法論，覆蓋架構中每一層的威脅、攻擊面與對應 countermeasure。

---

## 信任邊界 (Trust Boundaries)

```
                    Trust Boundary A (物理安全)
┌───────────────────────────────────────────────┐
│                  Data Center                    │
│  ┌─────────────────────────────────────────┐   │
│  │         Trust Boundary B (Network)       │   │
│  │  ┌──────────┐    ┌──────────┐           │   │
│  │  │ Tier 0   │    │ Mgmt     │           │   │
│  │  │ VLAN     │←──→│ VLAN     │           │   │
│  │  │ 100      │    │ 10.0.0.0/24          │   │
│  │  └────┬─────┘    └────┬─────┘           │   │
│  │       │               │                  │   │
│  │  ┌────┴─────┐    ┌────┴─────┐           │   │
│  │  │ Guest VM │    │ Host OS  │           │   │
│  │  │ Tier 0   │    │ (Dom0)   │           │   │
│  │  └────┬─────┘    └────┬─────┘           │   │
│  │       │ Trust Boundary C (Hypervisor)    │   │
│  │       └──────┬───────┘                  │   │
│  │         ┌────┴─────┐                     │   │
│  │         │ Hypervisor│                     │   │
│  │         │(KVM/Xen) │                     │   │
│  │         └──────────┘                     │   │
│  └─────────────────────────────────────────┘   │
│  Trust Boundary D (Host Hardware)              │
│  ┌─────────────────────────────────────────┐   │
│  │ BMC/iLO + TPM + SSD + NIC               │   │
│  └─────────────────────────────────────────┘   │
└───────────────────────────────────────────────┘
```

---

## STRIDE 威脅分析

### Tier 0: Guest VM (不裝 Agent)

| 威脅類型 | 威脅描述 | 影響 | 可能性 | 現有防護 | 殘餘風險 |
|---------|---------|------|--------|---------|---------|
| **S**poofing | 攻擊者偽造其他 VM 身分進行橫向移動 | High | Medium | VLAN 隔離 + 防火牆規則 | Low |
| **T**ampering | 攻擊者修改 Guest kernel 規避 VMI（如 syscall hook bypass） | Critical | Low | DRAKVUF Altp2m 監控 kernel text | Medium |
| **R**epudiation | 攻擊者在 Guest OS 內刪除 log | Medium | High | VMI 從外部擷取 syscall, 攻擊者無法刪除 | Low |
| **I**nformation Disclosure | 攻擊者透過 side-channel 讀取 Host 或其他 VM 的記憶體 | High | Low | KVM 硬體隔離 + SEV-SNP (如果支援) | Low |
| **D**enial of Service | 攻擊者觸發大量 VM Exit 導致 Host 過載 | High | Medium | Syscall whitelist + cgroup 限制 | Medium |
| **E**levation of Privilege | 攻擊者從 Guest 逃逸到 Hypervisor | Critical | Low | KVMI patched kernel 增加攻擊面 | Medium |

### Tier 0: Host OS (Dom0)

| 威脅類型 | 威脅描述 | 影響 | 可能性 | 現有防護 | 殘餘風險 |
|---------|---------|------|--------|---------|---------|
| **S**poofing | 未授權人員透過 SSH 登入 Dom0 | Critical | Low | MFA + SSH Key + Auditd | Low |
| **T**ampering | 攻擊者修改 DRAKVUF binary 或 config | Critical | Low | SELinux + Auditd + File Integrity | Low |
| **R**epudiation | 攻擊者偽造 DRAKVUF JSON log | High | Low | Filebeat 雙向 TLS + signed log | Low |
| **I**nformation Disclosure | 攻擊者讀取 DRAKVUF introspection 結果 | High | Low | Filebeat 加密傳輸 + OpenSearch ACL | Low |
| **D**enial of Service | 攻擊者 kill DRAKVUF process | Critical | Medium | systemd watchdog + Auditd alert | Medium |
| **E**levation of Privilege | Kernel 0-day 經 KVMI 介面提升權限 | Critical | Low | Kernel 凍結 + CVE tracking | Medium |

### Log Pipeline

| 威脅類型 | 威脅描述 | 影響 | 可能性 | 現有防護 | 殘餘風險 |
|---------|---------|------|--------|---------|---------|
| **S**poofing | 偽造 log source 餵假資料給 OpenSearch | High | Low | Filebeat TLS + API token | Low |
| **T**ampering | 中間人竄改 in-flight log | High | Low | TLS 加密通道 | Low |
| **R**epudiation | 未經授權刪除 OpenSearch index | Critical | Low | OpenSearch Security ACL | Low |
| **I**nformation Disclosure | 未經授權讀取 VMI log | Critical | Low | Field-level security + Role-based access | Low |
| **D**enial of Service | Log 暴增撐爆 OpenSearch 磁碟 | High | Medium | ISM rollover + disk watermark | Medium |
| **E**levation of Privilege | 從 Logstash -plugin 漏洞入侵 | High | Low | 最小化 plugin + 獨立 container | Low |

---

## Attack Trees

### 攻擊樹 1: 規避 VMI 監控

```
規避 DRAKVUF 監控
├── 1. 反偵測 VMI
│   ├── 1.1 RDTSC timing (成功機率: Low)
│   │   └── Mitigation: Jitter injection
│   ├── 1.2 檢測 EPT violation 頻率 (成功機率: Low)
│   │   └── Mitigation: Sampling mode
│   └── 1.3 檢測 TLB flush pattern (成功機率: Low)
│       └── Mitigation: Noise injection
├── 2. Bypass syscall hook
│   ├── 2.1 直接呼叫 sysenter (成功機率: Medium)
│   │   └── Mitigation: DRAKVUF hooks SYSENTER_MSR
│   ├── 2.2 修改 IA32_LSTAR MSR (成功機率: Low)
│   │   └── Mitigation: CR0.WP protection + EPT
│   └── 2.3 使用未 hook 的 syscall (成功機率: High)
│       └── Mitigation: Whitelist 策略 + 預設 pass 但 logging
└── 3. 攻擊 DRAKVUF 本身
    ├── 3.1 觸發 DRAKVUF OOM (成功機率: Medium)
    │   └── Mitigation: cgroup memory limit
    ├── 3.2 觸發 KVMI kernel panic (成功機率: Low)
    │   └── Mitigation: Watchdog auto-restart
    └── 3.3 從 Guest 逃逸到 Dom0 (成功機率: Very Low)
        └── Mitigation: SELinux + Kernel hardening
```

### 攻擊樹 2: 資料外洩不被發現

```
資料外洩不被發現
├── 1. 加密通道
│   ├── 1.1 HTTPS C2 (檢測 Success: NIDS JA3)
│   ├── 1.2 DNS tunneling (檢測 Success: NIDS DNS decode)
│   └── 1.3 使用合法雲端服務 (檢測 Success: 困難)
├── 2. 橫向移動
│   ├── 2.1 SMB/WMI (檢測 Success: NIDS + Wazuh)
│   ├── 2.2 SSH hijack (檢測 Success: Auditd execve)
│   └── 2.3 Pass-the-Hash (檢測 Success: Wazuh Sysmon)
└── 3. 清除痕跡
    ├── 3.1 刪除 Event Log (檢測 Success: VMI 已記錄 delete operation)
    ├── 3.2 修改 timestamp (檢測 Success: VMI 使用 Host TSC, 無法修改)
    └── 3.3 Unlink log file (檢測 Success: VMI unlink event)
```

---

## Threat Coverage Matrix

| ATT&CK Tactic | Technique | VMI | NIDS | Wazuh |
|---------------|-----------|-----|------|-------|
| TA0002 (Execution) | T1059 Command & Scripting | execve | - | Process tree |
| TA0005 (Defense Evasion) | T1562 Impair Defenses | process_vm_writev | - | FIM(svc/config) |
| TA0005 (Defense Evasion) | T1622 Debugger Evasion | ptrace | - | - |
| TA0008 (Lateral Movement) | T1021 Remote Services | connect | SMB/SSH decode | Network log |
| TA0011 (Command & Control) | T1572 Protocol Tunneling | socket, connect | DNS decode | - |
| TA0011 (Command & Control) | T1071 Application Layer | connect | TLS JA3 | DNS query |
| TA0010 (Exfiltration) | T1048 Exfiltration Over Network | write | DNS/HTTP size | Netflow |
| TA0003 (Persistence) | T1543 Create/Modify System Process | init_module | - | FIM(/etc/systemd) |

---

## Assumptions & Limitations

### Assumptions
1. Tier 0 Host 實體安全受控（資料中心門禁 + CCTV + BMC 存取受限）
2. Guest OS 不自動更新 kernel（手動 managed）
3. Intel Xeon 處理器（非 AMD）
4. 網路交換器支援 SPAN/RSPAN
5. 資安團隊具備 Linux kernel 除錯能力

### Known Limitations
1. VMI 無法監控 encrypted memory（如 Intel SGX enclave）
2. VMI 無法監控 Guest 關機後的離線攻擊
3. NIDS 無法解密 TLS 1.3 traffic（JA3 僅 fingerprint）
4. Wazuh Agent 本身有被 uninstall 的風險（需要 Host-level 防護）
5. 跨 tier 關聯分析依賴 ECS 標準化正確性（Logstash pipeline 錯誤會導致 false negative）

---

## Countermeasure Mapping

| Countermeasure | Blind Spot | Layer | Implementation |
|---------------|-----------|-------|---------------|
| DRAKVUF Watchdog | #1 | Host | systemd service + cgroup |
| Host SELinux + Auditd | #2 | Host | SELinux module + audit rules |
| Jitter Injection | #3 | VMI | drakvuf config |
| ECS Unified Pipeline | #4, #7 | Log | Logstash filter |
| Kernel Freeze + Symbol Gate | #5 | Guest | versionlock + staging validation |
| Intel-only T0 Hosts | #6 | Hardware | check-vmi-compatibility.sh |
| Suricata Port Mirror | #8 | Network | switch SPAN + af-packet |
| Redis Stream Buffer | #9 | Log | redis config |
| State Backup + Pinned VM | #10 | Host | drakvuf-state-backup.sh |
| Sanitizer + Field-level ACL | #11 | Log/OS | Logstash + OpenSearch security |
