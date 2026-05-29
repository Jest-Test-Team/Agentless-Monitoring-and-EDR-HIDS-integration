# Tier 2 Deployment Guide — Bare Metal

## Stack

| Component | Linux | Windows |
|-----------|-------|---------|
| Wazuh Agent | File integrity, rootkit | File integrity, rootkit |
| Osquery | Live SQL queries | Live SQL queries |
| Auditd | System call auditing | — (use Sysmon) |
| Sysmon | — | System call monitoring |
| AIDE | File integrity baseline | — |
| nftables | Network connection logging | Windows FW log |
| Risk Scanner | Weekly assessment | — |

## Linux Quick Start

```bash
# Full deployment
scripts/deploy-all.sh local tier2

# Or step by step:
scripts/phase-4-wazuh-deploy.sh 10.0.0.30 tier2
cp configs/auditd/rules.d/tier2-audit.rules /etc/audit/rules.d/
augenrules --load
cp configs/aide/aide.conf /etc/aide.conf
aide --init
scripts/phase-2-5-nftables-log.sh
scripts/run-risk-scanner.sh --all
```

## Windows Deployment

See [WINDOWS-TIER2.md](WINDOWS-TIER2.md) for Sysmon + Wazuh + Winlogbeat setup.

## AIDE Baseline

```bash
# Initialize database (run after clean OS install)
aide --init

# Move to database location
cp /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# Daily integrity check (cron)
echo "0 4 * * * root aide --check | logger -t aide" > /etc/cron.d/aide

# Verify
aide --check
```

## Verification

```bash
# AIDE database integrity
aide --check | tail -5

# nftables logging
tail -f /var/log/nftables.log

# All agents connected?
/var/ossec/bin/agent_control -l
```
