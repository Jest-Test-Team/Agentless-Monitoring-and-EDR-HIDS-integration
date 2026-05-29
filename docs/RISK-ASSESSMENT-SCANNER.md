# Risk Assessment Scanner

> 主機風險全掃描 + 結構化評分 + OpenSearch SIEM 儀表板

## 概述

risk-scanner 是一套部署在 Tier 1/2 機器的安全風險掃描系統，包裝 Lynis、osquery、trivy 等開源工具，加上 100+ 項自訂安全檢查，輸出結構化 JSON 風險評分至 OpenSearch，提供即時可視化的 SIEM 儀表板。

## 資料流

```
cron (每日) → risk-scanner.sh ─┬─ Lynis (CIS benchmark)
                                ├─ osquery (live queries)
                                ├─ trivy (CVE scan, 每週)
                                ├─ risk-lib.sh (自訂 100+ 檢查)
                                └─ risk-score-engine.py (評分)
                                    ↓ unified-risk.json
                                Filebeat → Logstash → OpenSearch
                                    ↓               ↓
                              risk-scores-* index  Risk Dashboard
```

## 風險評分架構

### 評分範圍

| 分數 | 等級 | 行動 |
|------|------|------|
| 0-15 | Low | 正常，無需行動 |
| 16-35 | Medium | 排程修復 |
| 36-60 | High | 優先修復 |
| 61-100 | Critical | 立即修復 |

### 五大類別

| 類別 | 代號 | 檢查數 | 權重 |
|------|------|--------|------|
| 系統強化 | system_hardening | 35 | 35% |
| 漏洞與套件 | cve_vulnerabilities | 25 | 25% |
| 網路安全 | network_security | 20 | 20% |
| 容器/應用安全 | container_security | 15 | 10% |
| 進階威脅 | advanced_threats | 20 | 10% |

### 評分公式

```
overall_risk = min(100, Σ(category_weight × category_score / max_possible))

category_score = Σ(check_weight × severity_mult)
severity_mult: critical=1.0, high=0.6, medium=0.3, low=0.1
```

## OpenSearch Index Mapping

```json
{
  "risk-scores-*": {
    "properties": {
      "host": { "type": "keyword" },
      "tier": { "type": "keyword" },
      "timestamp": { "type": "date" },
      "overall_risk": { "type": "float" },
      "severity": { "type": "keyword" },
      "categories": {
        "properties": {
          "system_hardening": { "properties": {
            "score": { "type": "float" },
            "max": { "type": "float" },
            "checks_passed": { "type": "integer" },
            "checks_total": { "type": "integer" },
            "critical_findings": { "type": "integer" }
          }},
          "cve_vulnerabilities": { "properties": {
            "score": { "type": "float" },
            "critical_count": { "type": "integer" },
            "high_count": { "type": "integer" }
          }},
          "network_security": { "properties": {
            "score": { "type": "float" },
            "open_ports_unexpected": { "type": "keyword" }
          }},
          "container_security": { "properties": {
            "score": { "type": "float" }
          }},
          "advanced_threats": { "properties": {
            "score": { "type": "float" },
            "rootkit_indicators": { "type": "integer" }
          }}
        }
      },
      "top_findings": {
        "properties": {
          "severity": { "type": "keyword" },
          "check": { "type": "keyword" },
          "detail": { "type": "text" },
          "score": { "type": "float" },
          "recommendation": { "type": "text" }
        }
      }
    }
  }
}
```

## 儀表板

### OpenSearch Dashboards 提供：

1. **整體風險總表**：所有主機的 overall_risk 一覽
2. **主機風險雷達圖**：單台主機的五類評分分布
3. **時間趨勢**：風險分數隨時間的變化
4. **Top 10 弱點**：最高分的 10 項 finding
5. **合規覆蓋率**：通過檢查 vs 總檢查數的比例

## 部署

見 `docs/DEPLOYMENT-RUNBOOK.md Phase 7`。

## 回歸測試

```bash
# 手動執行完整掃描（不回傳）
/usr/local/bin/risk-scanner.sh --dry-run

# 手動執行並回傳
/usr/local/bin/run-risk-scanner.sh --all

# 只跑 CVE 掃描
/usr/local/bin/run-risk-scanner.sh --cve
```
