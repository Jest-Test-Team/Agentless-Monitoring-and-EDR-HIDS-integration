# Architecture Assessment: Agentless VMI + EDR/HIDS + NIDS

## 執行摘要

本文件評估「DRAKVUF (VMI) + Wazuh (EDR/HIDS) + Suricata (NIDS) + OpenSearch/ELK」架構在實體主機群與 VM 分層環境中的可行性、風險與 mitigations。

### 評分總表

| 面向 | 評分 | 關鍵風險 |
|------|------|----------|
| 架構正確性 | 8/10 | 理論正確，但依賴多個非主流元件 |
| 生產就緒度 | 3/10 | DRAKVUF 非產品，KVMI 非 mainline kernel |
| 維運可行性 | 4/10 | 需要 kernel 工程師 + 虛擬化專家 |
| 合規覆蓋 | 6/10 | VMI 記憶體讀取的合規問題需提前處理 |
| 偵測覆蓋率 | 8/10 | VMI + NIDS + HIDS 三層覆蓋高 |
| 橫向擴展性 | 3/10 | DRAKVUF 不支援 live migration，Tier 0 難以擴展 |

---

## 架構圖

```
                           OpenSearch / ELK
                        ┌──────────────────┐
                        │  security-events-*│
                        │  (統一 ECS 索引)  │
                        └────────┬─────────┘
                                 │
                    ┌────────────┴────────────┐
                    │    Logstash Pipeline     │
                    │  (ECS Normalizer +       │
                    │   Sanitizer + Correlator)│
                    └────────────┬────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
         Tier 0             Tier 1             Tier 2
    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
    │ DRAKVUF     │    │ Wazuh Agent │    │ Wazuh Agent │
    │ + Suricata  │    │ + Osquery   │    │ + Osquery   │
    │ + Filebeat  │    │ + Filebeat  │    │ + Auditd    │
    │ (Host Dom0) │    │ (Guest OS)  │    │ (Host OS)   │
    └─────────────┘    └─────────────┘    └─────────────┘
```

---

## Blind Spot 風險矩陣

| # | Blind Spot | Severity | Mitigation Cost | 殘餘風險 |
|---|-----------|----------|----------------|---------|
| 1 | DRAKVUF 非產品 | Critical | 高（專職工程師維護 KVMI kernel） | 中 |
| 2 | Host 被打穿 | Critical | 中（SELinux + Auditd + MFA） | 低 |
| 3 | VMI 反偵測 | High | 低（Jitter + Sampling） | 低 |
| 4 | Wazuh+ELK 雙管線 | High | 低（統一 Logstash pipeline） | 極低 |
| 5 | 語意鴻溝 | Critical | 高（Kernel 凍結 + 符號驗證閘道） | 中 |
| 6 | AMD 不相容 | High | 中（硬體標準化 Intel Only） | 極低 |
| 7 | 跨層關聯困難 | High | 中（ECS 標準化 + Cross-index query） | 低 |
| 8 | 缺少 NIDS | High | 低（Port Mirror + Suricata） | 低 |
| 9 | Kafka 維運成本 | Medium | 中（Redis Stream 替代） | 極低 |
| 10 | DR/備份 | Medium | 高（Active/Standby + State backup） | 中 |
| 11 | 合規/稽核 | Medium | 中（Sanitizer + Field-level ACL） | 低 |
| 12 | 缺乏風險評分 | Medium | 低（Risk Scanner Script + Lynis Wrapper） | 極低 |

### 投入成本 vs 安全效益

```
效益 ↑          Tier 0 (VMI + NIDS + HIDS)
  |            ┌───┐
  |          1 │   │   ← 高效益，高投入
  |         ┌──┘   │
  |        │       │
  |    Tier 1 (Wazuh)
  |      ┌──┐
  |    3 │  │      ← 中等效益，中等投入
  |   ┌──┘  │
  |   │     │
  |   │ Tier 2 (Bare Metal Wazuh + Osquery)
  |   │ ┌──┐
  |   │ │  │      ← 低投入，中效益
  |   │ └──┘
  |   │ Tier 3 (Dev/Test)
  |   │  ┌┐
  |   │  ││       ← 極低投入
  |   │  └┘
  └───┴──────────────────────→ 投入成本
```

---

## 決策建議

### 建議立即導入（Low Hanging Fruit）

1. **Tier 2 & 3 First**：先在 Bare Metal 和 Dev/Test 部署 Wazuh + Osquery（零成本、低風險、立即見效）
2. **統一日誌 Pipeline**：建立 Logstash ECS normalizer，統一所有 log source 格式
3. **NIDS on Tier 0**：先做 Port Mirror + Suricata（無 agent 解決方案，純被動監控）

### 建議 PoC 驗證（先測試再生產）

4. **Tier 0 VMI**：先選一台非核心業務 VM 跑 DRAKVUF PoC 至少 30 天，驗證：
   - Host kernel stability（無 panic / OOM）
   - Guest OS performance impact（benchmark 前後對比）
   - Symbol table update cycle（驗證每次更新所需的 window）

### 建議不要做（除非資源充足）

5. **全量 Syscall 監控**：永遠使用 whitelist 模式，只 hook 最少必要 syscall
6. **Kafka 緩衝層**：除非日誌量 > 10K events/sec，否則 Redis Stream 足夠
7. **Live Migration**：Tier 0 VM 必須 pinned，不要嘗試支援 live migration

---

## 資源需求估算

| 角色 | 人數 | 技能要求 |
|------|------|----------|
| Linux Kernel Engineer | 1 | KVMI kernel patch maintenance, symbol table management |
| Security Engineer | 1 | Wazuh rules, Suricata rules, Logstash pipeline |
| DevOps/SRE | 1 | OpenSearch cluster, Kafka/Redis, monitoring |
| SOC Analyst | 1+ | Cross-tier correlation, incident response |

### 硬體最低需求

| 元件 | 規格 | 數量 (初始) |
|------|------|-----------|
| Tier 0 Host | Intel Xeon Gold, 512GB RAM, NVMe SSD | 2 (Active/Standby) |
| Tier 1/2 Host | 現有主機，加裝 Wazuh Agent | 依現有規模 |
| OpenSearch Node | 64GB RAM, 8 vCPU, SSD RAID-10 | 3 |
| Logstash Node | 16GB RAM, 4 vCPU | 2 |
| Suricata Node | 32GB RAM, 16 vCPU (多核心 RSS)，專用 NIC | 1 |
| Redis/Kafka | 32GB RAM, 4 vCPU | 3 |
