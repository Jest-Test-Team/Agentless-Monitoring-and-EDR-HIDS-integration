# Agentless Monitoring & EDR/HIDS Integration

實體主機群 + VM 的分層資安監控架構，結合 **DRAKVUF (Agentless VMI)**、**Wazuh (EDR/HIDS)**、**Suricata/Zeek (NIDS)** 與 **OpenSearch/ELK**，實現從 Kernel 到 Network 的縱深防禦。

## 架構總覽

```
┌─────────────────────────────────────────────────────────────────┐
│                    OpenSearch / ELK Stack                        │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ Wazuh Index  │  │  VMI Index   │  │  NIDS Index (Network)  │ │
│  └──────┬──────┘  └──────┬───────┘  └───────────┬────────────┘ │
│         │                │                       │              │
│  ┌──────┴──────┐  ┌─────┴──────┐  ┌────────────┴──────────┐    │
│  │ Wazuh       │  │ Logstash   │  │ Logstash (Packetbeat) │    │
│  │ Manager     │  │ (VMI JSON) │  │ (Flow/Suricata)       │    │
│  └──────┬──────┘  └─────┬──────┘  └────────────┬──────────┘    │
│         │               │                       │              │
│         └───────────────┼───────────────────────┘              │
│                         │ Kafka / Redis (緩衝層)               │
└─────────────────────────┼───────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────────┐
        │                 │                      │
   ┌────┴────┐      ┌────┴────┐          ┌──────┴──────┐
   │ Tier 0  │      │ Tier 1  │          │  Tier 2     │
   │ PRD VM  │      │ Service │          │  Bare Metal │
   │ (機敏)  │      │ VM      │          │  (實體機)   │
   └────┬────┘      └────┬────┘          └──────┬──────┘
        │                 │                      │
   DRAKVUF+VMI       Wazuh Agent           Wazuh Agent
   + NIDS (Port       + Auditd              + Osquery
    Mirror)                                  + Auditd
```

## 分層監控策略

| Tier | 對象 | 監控方式 | 侵入性 |
|------|------|----------|--------|
| **Tier 0** | PRD 機敏 VM | DRAKVUF (VMI) + NIDS (Suricata/Zeek) | 無 Agent |
| **Tier 1** | 內部服務 VM | Wazuh Agent + Auditd | 低 |
| **Tier 2** | Bare Metal | Wazuh Agent + Osquery + Auditd | 低 |
| **Tier 3** | Dev/Test | Wazuh Agent (輕量) | 低 |

## 文件索引

| 文件 | 說明 |
|------|------|
| [ARCHITECTURE-ASSESSMENT.md](docs/ARCHITECTURE-ASSESSMENT.md) | 完整架構可行性評估與 Mitigation |
| [BLINDSPOT-DEEP-DIVE.md](docs/BLINDSPOT-DEEP-DIVE.md) | 11 個盲點的 Root Cause、實戰案例、修補方案 |
| [TIER-MONITORING-STRATEGY.md](docs/TIER-MONITORING-STRATEGY.md) | 四層監控框架 + NIDS 整合 |
| [DEPLOYMENT-RUNBOOK.md](docs/DEPLOYMENT-RUNBOOK.md) | 實戰建置指南 |
| [THREAT-MODEL.md](docs/THREAT-MODEL.md) | STRIDE 威脅模型 |
