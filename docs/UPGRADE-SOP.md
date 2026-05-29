# Upgrade SOP — Standard Operating Procedures

## 1. Wazuh Components

### Wazuh Manager
```bash
# 1. Backup config
cp -r /var/ossec/etc /var/ossec/etc.backup.$(date +%Y%m%d)

# 2. Upgrade
curl -sO https://packages.wazuh.com/4.x/wazuh-install.sh
bash wazuh-install.sh --wazuh-server --version 4.9.0

# 3. Verify
systemctl status wazuh-manager
/var/ossec/bin/agent_control -l
```

### Wazuh Agent
```bash
# Agent upgrade (managed via Manager)
/var/ossec/bin/agent_upgrade.sh -a

# Or manual per host:
dnf update wazuh-agent
systemctl restart wazuh-agent
```

## 2. DRAKVUF

```bash
# Stop introspection
systemctl stop "drakvuf@*.service"

# Backup current binary
cp /usr/local/bin/drakvuf /usr/local/bin/drakvuf.$(date +%Y%m%d)

# Build new version
cd /usr/src/drakvuf
git pull
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local
make -j$(nproc)
make install

# Verify symbols
symbols-gate.sh prd-vm-01 \
  /var/lib/drakvuf/symbols/prd-vm-01/system.map \
  /var/lib/drakvuf/symbols/prd-vm-01/system.map.bak

# Restart
systemctl restart "drakvuf@*.service"
```

## 3. Guest OS Kernel (Tier 0)

```bash
# Step 1: Test in staging
#   1. Install new kernel in staging VM
#   2. Extract system.map
#   3. Run symbols-gate.sh
#   4. Run DRAKVUF for 48h validation

# Step 2: Production (30-min window)
#   1. Stop DRAKVUF: systemctl stop drakvuf@prd-vm-01
#   2. Deploy new symbols
#   3. Start DRAKVUF: systemctl start drakvuf@prd-vm-01
#   4. Verify: tail -f /var/log/drakvuf/prd-vm-01.json

# Step 3: Rollback
#   1. Restore old symbols
#   2. Restart DRAKVUF
```

## 4. OpenSearch

```bash
# Rolling upgrade (one node at a time)
# 1. Disable shard allocation
curl -X PUT "localhost:9200/_cluster/settings" -H 'Content-Type: application/json' -d'
{
  "transient": {
    "cluster.routing.allocation.enable": "none"
  }
}'

# 2. Upgrade node
systemctl stop opensearch
dnf update opensearch
systemctl start opensearch

# 3. Re-enable allocation
curl -X PUT "localhost:9200/_cluster/settings" -H 'Content-Type: application/json' -d'
{
  "transient": {
    "cluster.routing.allocation.enable": "all"
  }
}'

# 4. Wait for green status
curl -s 'localhost:9200/_cluster/health?wait_for_status=green&timeout=120s'
```

## 5. Rollback Plan

| Component | Rollback Action | RTO |
|-----------|----------------|-----|
| Wazuh Manager | Restore config + install previous version | 15 min |
| DRAKVUF | Restore binary + symbols from backup | 5 min |
| Guest Kernel | Boot previous kernel from GRUB | 2 min |
| OpenSearch | Snapshot restore | 30 min |
