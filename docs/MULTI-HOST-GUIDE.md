# Multi-Host Deployment Guide

Deploying the agentless monitoring stack across 10+ hosts using Ansible.

## Prerequisites

- Ansible 2.15+ on the management host
- SSH key-based access to all target hosts (root or sudo)
- Network connectivity between management host and all targets

## Inventory Structure

```
ansible/inventory/
├── hosts.ini          # Host groups per tier
└── group_vars/
    ├── all.yml        # Global vars
    ├── tier0.yml      # DRAKVUF vars
    ├── tier1.yml      # Wazuh+Osquery vars
    ├── tier2.yml      # Bare metal vars
    └── tier3.yml      # Dev/test vars
```

## Deployment Commands

```bash
# Deploy everything (all tiers)
cd ansible
ansible-playbook -i inventory/hosts.ini site.yml

# Deploy a specific tier
ansible-playbook -i inventory/hosts.ini site.yml --limit tier0

# Deploy specific tasks (tags)
ansible-playbook -i inventory/hosts.ini site.yml --tags "common"
ansible-playbook -i inventory/hosts.ini site.yml --tags "risk"

# Dry run
ansible-playbook -i inventory/hosts.ini site.yml --check --diff

# Deploy a single host
ansible-playbook -i inventory/hosts.ini site.yml --limit host-01
```

## Scaling Patterns

| Scale | Hosts | Method |
|-------|-------|--------|
| Small | 1-5 | Local deploy-all.sh |
| Medium | 5-50 | Ansible single control node |
| Large | 50-500 | Ansible AWX/Tower or Rundeck |
| Edge | 500+ | Unattended agent bootstrap |

## Logstash HA (2+ nodes)

For high availability, deploy Logstash on 2+ hosts with shared Redis consumption:

```yaml
# ansible/inventory/group_vars/all.yml
logstash_hosts: "10.0.0.20:5044,10.0.0.21:5044"
redis_host: "10.0.0.40"
redis_port: 6379
```

Filebeat automatically load-balances across all Logstash hosts:
```yaml
output.logstash:
  hosts: ["10.0.0.20:5044", "10.0.0.21:5044"]
  loadbalance: true
```

## OpenSearch Cluster (3+ nodes)

For production, deploy a 3-node OpenSearch cluster:

```yaml
opensearch_hosts: "10.0.0.10:9200,10.0.0.11:9200,10.0.0.12:9200"
```

## Rolling Updates

```bash
# Update one host at a time
for host in host-01 host-02 host-03; do
    ansible-playbook -i inventory/hosts.ini site.yml --limit "$host" --tags "common"
    echo "Waiting 60s for $host to stabilize..."
    sleep 60
done
```
