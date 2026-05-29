# Agentless Monitoring Stack — Dev Environment

使用 Docker Compose 在單機上啟動完整的開發/測試環境：

- OpenSearch (x3 nodes, single-node mode for dev)
- OpenSearch Dashboards (Kibana alternative)
- Logstash (with pre-configured pipeline)
- Filebeat (test log generator)
- Redis (buffer)

## 啟動方式

```bash
# 啟動所有服務
docker compose up -d

# 確認狀態
docker compose ps

# 檢查 Logstash pipeline
docker compose logs logstash

# 連接到 OpenSearch Dashboards
open http://localhost:5601
```

## 測試資料生成

```bash
# 模擬 DRAKVUF JSON 日誌
./generate-test-logs.sh

# 檢查是否被 Logstash 正確處理
docker compose logs logstash | grep "drakvuf"
```

## 目錄結構

```
docker/
├── docker-compose.yml              # 主 Compose 檔案
├── .env                            # 環境變數
├── logstash/pipeline/               # Logstash pipeline 配置
│   ├── 01-inputs.conf
│   ├── 02-filters.conf
│   ├── 03-outputs.conf
│   └── 04-risk-scanner.conf
├── opensearch/security/             # OpenSearch 安全配置
│   └── roles.yml
├── suricata/                        # Suricata 測試配置
│   └── suricata.yaml
└── generate-test-logs.sh           # 測試日誌產生器
```
