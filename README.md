# Agentless Monitoring & EDR/HIDS Integration

實體主機群 + VM 的分層資安監控架構，結合 **DRAKVUF (Agentless VMI)**、**Wazuh (EDR/HIDS)**、**Suricata/Zeek (NIDS)** 與 **OpenSearch/ELK**，實現從 Kernel 到 Network 的縱深防禦。

支援 **4 個安全層級**（Tier 0-3）、**多環境部署**（VM、裸機、邊緣裝置、終端、容器）、**Ansible 編排**與 **離線安裝**。

## 架構總覽

```
┌─────────────────────────────────────────────────────────────────┐
│                    OpenSearch / ELK Stack                        │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ Wazuh Index  │  │  VMI Index   │  │  NIDS Index (Network)  │ │
│  └──────┬──────┘  └──────┬───────┘  └───────────┬────────────┘ │
│         │                │                       │              │
│  ┌──────┴──────┐  ┌─────┴──────┐  ┌────────────┴──────────┐    │
│  │ Wazuh       │  │ Logstash   │  │ Logstash (Suricata)   │    │
│  │ Manager     │  │ (VMI JSON) │  │ (Flow/NIDS)           │    │
│  └──────┬──────┘  └─────┬──────┘  └────────────┬──────────┘    │
│         │               │                       │              │
│         └───────────────┼───────────────────────┘              │
│                         │ Redis Buffer (緩衝層)                │
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
    + NIDS (Port       + Osquery             + Osquery
     Mirror)            + Auditd              + Auditd + AIDE
                                           + nftables log
```

## 分層監控策略

| Tier | 對象 | 監控方式 | 侵入性 | 部署方式 |
|------|------|----------|--------|----------|
| **Tier 0** | PRD 機敏 VM | DRAKVUF (VMI) + Suricata (NIDS) + Dom0 Wazuh | 無 Agent (Guest) | `deploy-all.sh local tier0` |
| **Tier 1** | 內部服務 VM | Wazuh Agent + Osquery + Auditd | 低 | `deploy-all.sh local tier1` |
| **Tier 2** | Bare Metal | Wazuh Agent + Osquery + Auditd + AIDE + nftables | 低 | `deploy-all.sh local tier2` |
| **Tier 3** | Dev/Test/Edge | Wazuh Agent (輕量) + Rsyslog 直送 | 最低 | `deploy-edge-agent.sh` |

## 快速開始

```bash
# 單機部署 (Tier 0)
sudo scripts/deploy-all.sh local tier0

# Ansible 多機部署
cd ansible && ansible-playbook -i inventory/hosts.ini site.yml --limit tier1

# 邊緣裝置部署
sudo scripts/deploy-edge-agent.sh

# 離線安裝包
scripts/build-offline-bundle.sh v1.0.0
```

## 專案結構

```
├── scripts/           # 部署腳本 (Phase 0-6 + 風險掃描 + 工具)
├── configs/           # 獨立設定檔 (所有元件)
│   ├── drakvuf/       # DRAKVUF inspector + systemd service
│   ├── suricata/      # Suricata NIDS 設定
│   ├── logstash/      # Logstash pipeline (4 stages)
│   ├── filebeat/      # Filebeat log shipping
│   ├── redis/         # Redis buffer configs
│   ├── wazuh/         # ossec.conf per tier
│   ├── osquery/       # Osquery schedule config
│   ├── auditd/        # Auditd rules per tier
│   ├── aide/          # AIDE file integrity config
│   ├── selinux/       # SELinux policy module
│   ├── opensearch/    # ISM policy + roles
│   ├── rsyslog/       # Rsyslog direct shipping
│   ├── promtail/      # Promtail (Loki) config
│   ├── nginx/         # OpenSearch Dashboards reverse proxy
│   └── docker/        # Edge agent sidecar
├── ansible/           # Ansible 多機編排
│   ├── inventory/     # Hosts + group vars
│   └── playbooks/     # Per-tier playbooks
├── docs/              # 文件
└── docker/            # 開發環境 (Docker Compose)
```

## 文件索引

| 文件 | 說明 |
|------|------|
| **核心設計** | |
| [ARCHITECTURE-ASSESSMENT.md](docs/ARCHITECTURE-ASSESSMENT.md) | 完整架構可行性評估與 Mitigation |
| [BLINDSPOT-DEEP-DIVE.md](docs/BLINDSPOT-DEEP-DIVE.md) | 11 個盲點的 Root Cause、實戰案例、修補方案 |
| [TIER-MONITORING-STRATEGY.md](docs/TIER-MONITORING-STRATEGY.md) | 四層監控框架 + NIDS 整合 |
| [THREAT-MODEL.md](docs/THREAT-MODEL.md) | STRIDE 威脅模型 |
| **部署指南** | |
| [DEPLOYMENT-RUNBOOK.md](docs/DEPLOYMENT-RUNBOOK.md) | 實戰建置指南 (Phase 0-7) |
| [MULTI-HOST-GUIDE.md](docs/MULTI-HOST-GUIDE.md) | Ansible 多機部署 |
| [TIER1-DEPLOYMENT.md](docs/TIER1-DEPLOYMENT.md) | Tier 1 部署說明 |
| [TIER2-DEPLOYMENT.md](docs/TIER2-DEPLOYMENT.md) | Tier 2 部署說明 (含 Windows) |
| [TIER3-DEPLOYMENT.md](docs/TIER3-DEPLOYMENT.md) | Tier 3 輕量部署 |
| [EDGE-DEVICE-GUIDE.md](docs/EDGE-DEVICE-GUIDE.md) | 邊緣/終端/IoT 裝置部署 |
| [WINDOWS-TIER2.md](docs/WINDOWS-TIER2.md) | Windows Sysmon + Wazuh 指南 |
| [OFFLINE-DEPLOYMENT.md](docs/OFFLINE-DEPLOYMENT.md) | 離線/氣隙環境部署 |
| [UPGRADE-SOP.md](docs/UPGRADE-SOP.md) | 升級標準作業程序 |
