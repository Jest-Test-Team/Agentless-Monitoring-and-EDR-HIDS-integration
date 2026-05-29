# Tier 1 Deployment Guide — Internal Service VM

## Stack

| Component | Purpose |
|-----------|---------|
| Wazuh Agent | File integrity, rootkit detection, log collection |
| Osquery | Live SQL queries (processes, ports, kernel) |
| Auditd | System call auditing (execve, file access) |
| Risk Scanner | Weekly security posture assessment |
| Filebeat | Log shipping to Logstash |

## Quick Start

### Ansible
```bash
ansible-playbook ansible/site.yml --limit tier1
```

### Local
```bash
scripts/deploy-all.sh local tier1
```

### Manual
```bash
# Wazuh Agent + Osquery + Auditd
scripts/phase-4-wazuh-deploy.sh 10.0.0.30 tier1

# Deploy audit rules
cp configs/auditd/rules.d/tier1-audit.rules /etc/audit/rules.d/
augenrules --load

# Run risk scanner
scripts/run-risk-scanner.sh --quick
```

## Verification

```bash
# Wazuh agent connected?
/var/ossec/bin/agent_control -l

# Osquery running?
osqueryi "SELECT * FROM osquery_info;"

# Auditd rules loaded?
auditctl -l | head -10

# Logs reaching OpenSearch?
curl -s 'http://10.0.0.10:9200/_cat/indices/security-events-*'
```
