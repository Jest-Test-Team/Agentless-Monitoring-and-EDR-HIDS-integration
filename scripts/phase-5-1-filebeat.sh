#!/bin/bash
# Phase 5.1: Filebeat Configuration (Tier 0 Host - DRAKVUF JSON shipping)
set -euo pipefail

LOGSTASH_HOST="${1:-10.0.0.20}"

echo "[*] Phase 5.1: Filebeat Configuration"
echo "  Logstash target: $LOGSTASH_HOST:5044"
echo "========================================"

dnf install -y filebeat

cat > /etc/filebeat/filebeat.yml << FB
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/drakvuf/*.json
  json.keys_under_root: true
  json.overwrite_keys: true
  json.add_error_key: true
  fields_under_root: true
  fields:
    log_type: drakvuf
    tier: tier0

- type: log
  enabled: true
  paths:
    - /var/log/suricata/eve.json
  json.keys_under_root: true
  json.overwrite_keys: true
  fields_under_root: true
  fields:
    log_type: suricata
    tier: tier0

output.logstash:
  hosts: ["${LOGSTASH_HOST}:5044"]
  loadbalance: true
  ssl.enabled: false
  ttl: 300s

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat.log
  keepfiles: 7
  permissions: 0644
FB

# Filebeat keystore for TLS (if needed)
# echo "password" | filebeat keystore add LOGSTASH_PASSWORD

systemctl enable filebeat
systemctl restart filebeat

echo "[+] Filebeat configured for DRAKVUF + Suricata logs"
echo "    Verify: filebeat test output"
