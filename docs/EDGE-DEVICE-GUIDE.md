# Edge / Terminal / IoT Device Deployment Guide

This guide covers deploying monitoring agents on constrained, remote, or non-standard devices: ARM SBCs (Raspberry Pi), thin clients, edge gateways, IoT devices, and containerized hosts.

## Architecture Decision Tree

```
Is the device x86_64 with >2GB RAM?
├── YES → Can it run Wazuh Agent?
│   ├── YES → Use Tier 3 (deploy-edge-agent.sh)
│   └── NO  → Use Rsyslog sidecar only
└── NO  → Is it ARM (aarch64/armv7)?
    ├── YES → Use Rsyslog + optional Wazuh agent (limited)
    └── NO  → Unsupported; use syslog forwarding only
```

## Supported Platforms

| Architecture | OS | RAM | Agent |
|-------------|----|-----|-------|
| x86_64 | RHEL 9 / CentOS 9 / Rocky 9 | ≥2GB | Full Wazuh + Rsyslog |
| x86_64 | Ubuntu 20.04+ / Debian 11+ | ≥1GB | Rsyslog only (no Wazuh rpm) |
| aarch64 | Rocky 9 / Ubuntu 22.04+ | ≥2GB | Wazuh (if available) + Rsyslog |
| aarch64 | Raspberry Pi OS / Debian | ≥1GB | Rsyslog only |
| armv7l | Raspberry Pi OS (32-bit) | ≥512MB | Rsyslog only |
| container | Any (Docker/podman) | — | Rsyslog sidecar (docker-compose.edge-agent.yml) |

## Installation Methods

### Method 1: Standard (Online)

```bash
# On the edge device
curl -sL https://raw.githubusercontent.com/your-org/agentless-monitoring/main/scripts/deploy-edge-agent.sh | bash
```

### Method 2: Offline / Air-Gapped

On a build machine with internet access:

```bash
# Build the offline bundle (downloads all RPMs)
scripts/build-offline-bundle.sh v1.0.0

# Copy to the edge device (USB, SCP, etc.)
scp /tmp/agentless-offline/agentless-offline-1.0.0.tar.gz edge-device:/tmp/

# On the edge device:
tar xzf /tmp/agentless-offline-1.0.0.tar.gz
sudo ./install-offline.sh
```

### Method 3: Container Sidecar (Immutable / Containerized Hosts)

For hosts that cannot install RPMs (immutable OS, CoreOS, Fedora IoT, Kubernetes nodes):

```yaml
# Use configs/docker/docker-compose.edge-agent.yml
# Ships logs via rsyslog to central Logstash
docker compose -f docker-compose.edge-agent.yml up -d
```

### Method 4: Ansible (Multi-Device Fleet)

```bash
# Deploy to all edge devices in the [tier3] group
ansible-playbook ansible/site.yml --limit tier3 --tags "rsyslog"

# Or use the orchestrator
scripts/deploy-all.sh ansible tier3
```

## Edge-Specific Configuration

### Rsyslog Optimizations for Low-Bandwidth / Cellular Links

```bash
# Add to /etc/rsyslog.d/90-logstash.conf
# Compress logs before sending (if Logstash supports it)
$ActionSendStreamDriver gtls
$ActionSendStreamDriverMode 1
$ActionSendStreamDriverAuthMode x509/name
$ActionSendStreamDriverPermittedPeer *

# Queue in memory (not disk) for flash storage longevity
$ActionQueueType LinkedList
$ActionQueueSize 10000
$ActionQueueDiscardMsg 1000
```

### Wazuh Agent Memory Tuning

```xml
<global>
  <memory_limit>256</memory_limit>
  <max_eps>50</max_eps>
  <disable_fim>yes</disable_fim>
</global>
```

## Monitoring Edge Device Health

```bash
# Built-in health check
edge-healthcheck.sh

# Syslog query (central Logstash)
# Run on management host:
curl -s 'http://10.0.0.10:9200/_search?q=host.name:edge-*&sort=@timestamp:desc' | jq
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent won't install on ARM | No Wazuh ARM rpm | Use Rsyslog only |
| Rsyslog not sending to Logstash | Firewall | `firewall-cmd --add-port 5514/tcp` |
| High memory on edge device | Wazuh FIM enabled | Set `<memory_limit>256</memory_limit>` |
| Logs truncated on cellular | MTU too high | Add `$MainMsgQueueSize 5000` to rsyslog |
