# Offline / Air-Gapped Deployment Guide

For environments without internet access, use the offline bundle builder.

## Build Bundle (on internet-connected machine)

```bash
# Build the offline bundle
scripts/build-offline-bundle.sh v1.0.0

# Output:
# /tmp/agentless-offline/agentless-offline-1.0.0.tar.gz
```

## Bundle Contents

```
agentless-offline-1.0.0.tar.gz
├── install-offline.sh     # Offline installer
├── scripts/               # All bash/Python scripts
├── configs/               # All configuration files
├── docs/                  # Documentation
├── ansible/               # Ansible playbooks
└── rpms/                  # Pre-downloaded RPMs
    ├── wazuh-agent-4.9.0-1.x86_64.rpm
    ├── osquery-5.12.0-1.linux.x86_64.rpm
    ├── filebeat-7.17.24-x86_64.rpm
    ├── suricata-7.0.3-1.el9.x86_64.rpm
    ├── redis-7.2.4-1.el9.x86_64.rpm
    ├── aide-0.18.6-1.el9.x86_64.rpm
    └── ...
```

## Install on Air-Gapped Host

```bash
# Copy bundle to target
scp agentless-offline-1.0.0.tar.gz user@target:/tmp/

# On target:
tar xzf /tmp/agentless-offline-1.0.0.tar.gz
cd agentless-offline-1.0.0
sudo ./install-offline.sh

# Then run deploy for specific tier
sudo ./scripts/deploy-all.sh local tier0
```

## Notes

- Some RPMs may have dependencies that need `--nodeps` on minimal systems
- For EPEL dependencies, add the EPEL RPM to the bundle manually
- The bundle does not include OS base packages (kernel, glibc, etc.)
- Test the bundle in a staging environment before air-gapped deployment
