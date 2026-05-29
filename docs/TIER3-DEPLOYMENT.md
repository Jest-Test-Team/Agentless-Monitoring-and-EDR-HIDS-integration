# Tier 3 Deployment Guide — Dev/Test (Lightweight)

## Stack

| Component | Purpose |
|-----------|---------|
| Wazuh Agent (minimal) | Rootkit detection only |
| Rsyslog | Direct log shipping to Logstash (port 5514) |
| Health check | Basic device health monitoring |

## Quick Start

```bash
# Full deployment
scripts/deploy-all.sh local tier3

# Or step by step:
scripts/phase-4-wazuh-deploy.sh 10.0.0.30 tier3
INSTALL_WAZUH=no scripts/phase-4-1-rsyslog-tier3.sh
```

## Log Pipeline

```
Tier 3 Host
  └─ Rsyslog ──tcp/5514──→ Logstash ──→ OpenSearch
  └─ Wazuh (minimal) ──tcp/1514──→ Wazuh Manager ──→ Logstash ──→ OpenSearch
```

## Logstash Input (must be configured on Logstash server)

Add to `/etc/logstash/conf.d/01-inputs.conf`:
```
input {
  syslog {
    port => 5514
    type => "syslog"
  }
}
```

## Retention

Tier 3 indices are kept for 30 days (vs 365 for Tier 0/2, 90 for Tier 1).

Apply ISM policy:
```bash
curl -X PUT 'http://10.0.0.10:9200/_plugins/_ism/policies/security-events-retention-tier3' \
  -H 'Content-Type: application/json' \
  -d @/etc/opensearch/ism-policy-tier3.json
```

## Verification

```bash
# Logs reaching Logstash?
logger -t test "Tier3 test message"
tail -f /var/log/messages | grep omfwd

# Wazuh agent?
/var/ossec/bin/ossec-control status
```
