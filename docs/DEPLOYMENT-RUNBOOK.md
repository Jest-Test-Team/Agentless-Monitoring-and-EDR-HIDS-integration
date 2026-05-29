# Deployment Runbook

> 實戰建置指南：從裸機到運行的完整步驟

---

## Phase 0: 前置檢查

### 0.1 硬體相容性

```bash
# 每台預計跑 DRAKVUF 的 Host 執行
/usr/local/bin/check-vmi-compatibility.sh

# 預期輸出 (Intel):
# [OK] CPU: Intel
# [OK] Intel VT-x / EPT supported
# [OK] Altp2m enabled

# 預期輸出 (AMD):
# [WARN] AMD EPYC: KVMI support experimental, Altp2m unavailable
# → 此 Host 只能跑 Tier 1/2
```

### 0.2 網路拓樸

```
Management Network (10.0.0.0/24)
├── OpenSearch Cluster: 10.0.0.10-12
├── Logstash: 10.0.0.20-21
├── Wazuh Manager: 10.0.0.30
├── Kafka/Redis: 10.0.0.40-42
└── Suricata: 10.0.0.50

Tier 0 Network (192.168.100.0/24) — 獨立 VLAN
├── Host-01 (DRAKVUF): 192.168.100.1
├── Host-02 (DRAKVUF Standby): 192.168.100.2
├── VM-prd-db-01: 192.168.100.10 (vMotion pinned)
└── Port Mirror → Suricata (bond0.100)

Tier 1 Network (172.16.0.0/16)
└── VM-srv-*: Wazuh Agent

Tier 2 Network (10.0.1.0/24)
└── BM-*: Wazuh Agent + Osquery
```

---

## Phase 1: Host OS & Kernel

### 1.1 安裝 Host OS

```bash
# 使用 CentOS Stream 9 / RHEL 9（5.14.x kernel）
# 最小安裝，不要 GUI
# 磁碟分區建議:
# /boot: 1GB
# /: 100GB (ext4/xfs)
# /var/log: 200GB (獨立分區，避免 log 撐爆系統)
# /var/lib/libvirt: 剩餘空間 (VM 映像)

# 安裝基礎工具
dnf install -y epel-release
dnf groupinstall -y "Development Tools"
dnf install -y \
    git wget curl vim \
    libvirt virt-install virt-manager \
    qemu-kvm qemu-img \
    bridge-utils net-tools \
    kernel-devel kernel-headers \
    elfutils-libelf-devel \
    openssl-devel \
    python3 python3-pip \
    audit audit-libs \
    filebeat
```

### 1.2 編譯 KVMI Kernel

```bash
# Clone KVMI kernel
git clone https://github.com/KVM-VMI/kvm-vmi.git /usr/src/kvmi-kernel
cd /usr/src/kvmi-kernel
git checkout linux-5.15.y  # 或其他 KVMI 支援的版本

# Apply KVMI patch
patch -p1 < kvmi/patches/v5.15/kvm-introspection.patch

# 編譯 kernel
cp /boot/config-$(uname -r) .config
make olddefconfig
# 確認以下選項啟用:
# CONFIG_KVM=y
# CONFIG_KVM_INTEL=y
# CONFIG_KVM_AMD=y (optional)
# CONFIG_KVM_INTROSPECTION=y (KVMI)
# CONFIG_KVM_EVENTFD=y

make -j$(nproc)
make modules_install
make install

# 更新 grub
grub2-mkconfig -o /boot/grub2/grub.cfg
grubby --set-default /boot/vmlinuz-5.15.x-kvmi

# 驗證 KVMI module
lsmod | grep kvmi
# 預期: kvmi  or kvm_introspection
```

### 1.3 Host OS Hardening

```bash
# 1. SSH Hardening
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSH'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AuthenticationMethods publickey
SSH

# 2. Firewall (Tier 0 Host)
firewall-cmd --permanent --zone=trusted --add-source=10.0.0.0/24
firewall-cmd --permanent --zone=trusted --add-port=22/tcp
firewall-cmd --permanent --zone=trusted --add-port=16509/tcp  # libvirt TLS
firewall-cmd --permanent --zone=trusted --add-port=5900-5910/tcp  # VNC
firewall-cmd --permanent --zone=block --change-interface=eth0
firewall-cmd --reload

# 3. SELinux
cat > /etc/selinux/drakvuf.te << 'TE'
module drakvuf 1.0;
require {
    type drakvuf_t;
    type virtd_t;
    class process { signal };
    class file { read write };
}
allow drakvuf_t self:process { signal };
allow drakvuf_t virtd_t:file { read write };
TE
checkmodule -M -m -o drakvuf.mod drakvuf.te
semodule_package -o drakvuf.pp -m drakvuf.mod
semodule -i drakvuf.pp

# 4. Auditd
cat > /etc/audit/rules.d/host-hardening.rules << 'AUDIT'
# Kernel tampering
-w /usr/local/bin/drakvuf -p wa -k drakvuf_binary
-w /etc/drakvuf/ -p wa -k drakvuf_config
-w /dev/kvmi -p rwa -k kvmi_device
-w /etc/filebeat/ -p wa -k filebeat_config
# SSH monitoring
-w /var/log/secure -p wa -k ssh_login
-w /etc/ssh/sshd_config -p wa -k ssh_config
# System critical files
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
AUDIT
service auditd restart
```

---

## Phase 2: DRAKVUF & LibVMI

### 2.1 安裝 DRAKVUF

```bash
# Install dependencies
dnf install -y \
    cmake make gcc gcc-c++ \
    json-c-devel \
    libvirt-devel \
    glib2-devel \
    glibc-devel \
    xen-devel  # optional, if using Xen

# Build LibVMI
git clone https://github.com/libvmi/libvmi.git /usr/src/libvmi
cd /usr/src/libvmi
autoreconf -i
./configure --enable-kvm
make -j$(nproc)
make install
ldconfig

# Build DRAKVUF
git clone https://github.com/tklengyel/drakvuf.git /usr/src/drakvuf
cd /usr/src/drakvuf
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local
make -j$(nproc)
make install

# Verify
drakvuf --version
# 預期: DRAKVUF version x.x.x
```

### 2.2 配置 DRAKVUF

```bash
# 主配置檔
mkdir -p /etc/drakvuf

cat > /etc/drakvuf/inspector.json << 'CFG'
{
    "inject_jitter": true,
    "jitter_min_us": 50,
    "jitter_max_us": 500,
    "memory_access_monitoring": {
        "enabled": true,
        "mode": "sampling",
        "sample_interval_ms": 5000,
        "sample_duration_ms": 100,
        "sample_regions": ["kernel_text", "module_text", "process_text"]
    },
    "syscalls": ["execve", "fork", "clone", "init_module", "connect",
                 "bind", "socket", "ptrace", "process_vm_writev",
                 "process_vm_readv"],
    "strategy": "whitelist",
    "default_action": "pass"
}
CFG

# systemd service
cat > /etc/systemd/system/drakvuf@.service << 'SVC'
[Unit]
Description=DRAKVUF Introspection for %I
After=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/drakvuf \
    -r %I \
    -i /etc/drakvuf/inspector.json \
    -k /var/lib/drakvuf/symbols/%I/system.map \
    --json-file /var/log/drakvuf/%I.json \
    --json-stats /var/log/drakvuf/%I-stats.json
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
MemoryMax=4G

[Install]
WantedBy=multi-user.target
SVC
```

### 2.3 符號表管理

```bash
# Linux Guest: 從 Guest 提取 system.map
cat > /usr/local/bin/fetch-linux-symbols.sh << 'SCRIPT'
#!/bin/bash
GUEST=$1
OUTPUT_DIR="/var/lib/drakvuf/symbols/${GUEST}"
mkdir -p "${OUTPUT_DIR}"

# 方式 1: 透過 qemu-agent
virsh qemu-agent-command "${GUEST}" \
    '{"execute":"guest-exec","arguments":{"path":"/bin/cat","arg":["/boot/System.map-$(uname -r)"],"capture-output":true}}'

# 方式 2: 從 kernel RPM 提取
KERNEL_VER=$(virsh qemu-agent-command "${GUEST}" \
    '{"execute":"guest-exec","arguments":{"path":"/usr/bin/uname","arg":["-r"],"capture-output":true}}' | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['return'])")
rpm2cpio kernel-${KERNEL_VER}.rpm | cpio -idm ./boot/System.map-${KERNEL_VER}
cp boot/System.map-${KERNEL_VER} "${OUTPUT_DIR}/system.map"

echo "Symbols saved to ${OUTPUT_DIR}/system.map"
SCRIPT
chmod +x /usr/local/bin/fetch-linux-symbols.sh

# Windows Guest: 下載 PDB
cat > /usr/local/bin/fetch-windows-symbols.py << 'PYTHON'
#!/usr/bin/env python3
import sys
import os
import requests

GUEST = sys.argv[1]
OUTPUT_DIR = f"/var/lib/drakvuf/symbols/{GUEST}"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# 下載 ntoskrnl.pdb 的方式取決於 Windows 版本
# 可以使用 Microsoft Symbol Server 或 dump from Guest
# 此處為示意，實務上建議使用 symchk.exe 在 Guest 內執行後傳回

print(f"Symbols for {GUEST} will be saved to {OUTPUT_DIR}")
PYTHON
chmod +x /usr/local/bin/fetch-windows-symbols.py
```

---

## Phase 3: Suricata NIDS

### 3.1 安裝 Suricata

```bash
dnf install -y suricata

# 配置 Tier 0 port mirror interface
cat > /etc/suricata/suricata.yaml << 'SURI'
%YAML 1.1
---
vars:
  address-groups:
    TIER0_NETWORK: "[192.168.100.0/24]"
    EXTERNAL_NET: "!$TIER0_NETWORK"

af-packet:
  - interface: bond0.100
    cluster-id: 99
    cluster-type: cluster_qm
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes

rule-files:
  - suricata.rules
  - emerging-exploit.rules
  - emerging-malware.rules

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: /var/log/suricata/eve.json
      types:
        - alert: { payload: yes, payload-buffer-size: 4kb }
        - http: { extended: yes }
        - dns: { query: yes, rdata: yes }
        - tls: { extended: yes }
        - flow: {}
SURI

systemctl enable --now suricata
```

### 3.2 配置 Port Mirror

```bash
# 交換器端 (Cisco 範例):
# interface GigabitEthernet1/0/1
#   description Tier0 VM Port
#   switchport mode access
#   switchport access vlan 100
#   !
# interface GigabitEthernet1/0/48
#   description Suricata Monitor Port
#   switchport mode access
#   switchport access vlan 100
#   !
# monitor session 1 source interface Gi1/0/1 - 24
# monitor session 1 destination interface Gi1/0/48

# Linux bridge 端 (軟體鏡像):
# ip link add name bond0.100 link bond0 type vlan id 100
# ip link set bond0.100 promisc on
# ip link set bond0.100 up
```

---

## Phase 4: Wazuh Deployment

### 4.1 Wazuh Manager (獨立伺服器)

```bash
# 在 Management Server (10.0.0.30) 上執行
curl -sO https://packages.wazuh.com/4.x/wazuh-install.sh
bash wazuh-install.sh --wazuh-server
```

### 4.2 Wazuh Agent (Tier 1/2/3)

```bash
# Tier 1 Linux VM
WAZUH_MANAGER="10.0.0.30"
curl -s https://packages.wazuh.com/4.x/wazuh-install.sh | bash -s -- agent $WAZUH_MANAGER
systemctl enable --now wazuh-agent

# Tier 2 Bare Metal
curl -s https://packages.wazuh.com/4.x/wazuh-install.sh | bash -s -- agent $WAZUH_MANAGER
dnf install -y osquery
systemctl enable --now osquery

# Tier 3 Dev/Test (最小配置)
curl -s https://packages.wazuh.com/4.x/wazuh-install.sh | bash -s -- agent $WAZUH_MANAGER
# 只啟用 rootcheck
```

### 4.3 Wazuh → Logstash 輸出

```bash
# 在 Wazuh Manager 上配置
cat >> /var/ossec/etc/ossec.conf << 'CONF'
<ossec_config>
  <integration>
    <name>logstash</name>
    <hook_url>http://10.0.0.20:5044</hook_url>
    <rule_id>100000,100001</rule_id>
    <alert_format>json</alert_format>
  </integration>
</ossec_config>
CONF
systemctl restart wazuh-manager
```

---

## Phase 5: Log Pipeline

### 5.1 Filebeat (資料收集層)

```bash
# Host 端 Filebeat (每台 Tier 0 Host)
cat > /etc/filebeat/filebeat.yml << 'FB'
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/drakvuf/*.json
  json.keys_under_root: true
  json.overwrite_keys: true
  fields:
    log_type: drakvuf

output.logstash:
  hosts: ["10.0.0.20:5044", "10.0.0.21:5044"]
  loadbalance: true
  ssl.enabled: false  # production 要啟用

filebeat.config.modules:
  path: ${path.config}/modules.d/*.yml
  reload.enabled: true
FB

systemctl enable --now filebeat
```

### 5.2 Logstash Pipeline

```bash
cat > /etc/logstash/conf.d/01-inputs.conf << 'CONF'
input {
  beats { port => 5044 }
  redis {
    data_type => "list"
    key => "drakvuf-queue"
    host => "10.0.0.40"
    port => 6379
    batch_count => 500
    codec => json
  }
}
CONF

cat > /etc/logstash/conf.d/02-filters.conf << 'CONF'
filter {
  # ECS normalizer
  if [fields][log_type] == "drakvuf" {
    mutate {
      rename => {
        "TimeStamp" => "@timestamp"
        "VMName" => "[host][name]"
        "ProcessId" => "[process][pid]"
        "ParentProcessId" => "[process][parent][pid]"
        "Image" => "[process][executable]"
        "EventId" => "[event][code]"
      }
    }
    # Sanitize PII
    mutate {
      gsub => [
        "[process][command_line]", "(-p\\s+)\\S+", "\\1[REDACTED]"
      ]
      remove_field => ["[process][environment]", "[memory][buffer]"]
    }
  }
}
CONF

cat > /etc/logstash/conf.d/03-outputs.conf << 'CONF'
output {
  elasticsearch {
    hosts => ["10.0.0.10:9200", "10.0.0.11:9200", "10.0.0.12:9200"]
    index => "security-events-%{+YYYY.MM.dd}"
    document_id => "%{[event][hash]}"
    action => "index"
  }
}
CONF

systemctl enable --now logstash
```

### 5.3 Redis Buffer (輕量替代 Kafka)

```bash
dnf install -y redis

cat > /etc/redis/redis-tier0.conf << 'RCONF'
bind 0.0.0.0
port 6379
maxmemory 10gb
maxmemory-policy allkeys-lru
save 3600 1
save 300 100
RCONF

systemctl enable --now redis@redis-tier0
```

---

## Phase 6: 監控與維護

### 6.1 健康檢查腳本

```bash
cat > /usr/local/bin/healthcheck-all.sh << 'HEALTH'
#!/bin/bash
# 綜合健康檢查

echo "=== DRAKVUF Status ==="
systemctl is-active drakvuf@*.service 2>/dev/null || echo "No drakvuf services"

echo "=== Suricata Status ==="
systemctl is-active suricata
tail -5 /var/log/suricata/stats.log 2>/dev/null | grep -E "kernel|drop"

echo "=== Log Pipeline ==="
systemctl is-active filebeat
systemctl is-active logstash
systemctl is-active redis

echo "=== Host Auditd Alerts ==="
ausearch -k drakvuf_binary --start recent --format text 2>/dev/null | tail -5

echo "=== Disk Usage ==="
df -h /var/log/
du -sh /var/log/drakvuf/ 2>/dev/null
du -sh /var/log/suricata/ 2>/dev/null
HEALTH
chmod +x /usr/local/bin/healthcheck-all.sh

# cron job 每小時執行
echo "0 * * * * root /usr/local/bin/healthcheck-all.sh | logger -t healthcheck" \
    > /etc/cron.d/healthcheck
```

### 6.2 升級 SOP

```markdown
# Guest OS Kernel 升級 SOP

## Step 1: 測試環境驗證
1. 在 staging VM 安裝新 kernel
2. 擷取 system.map / PDB
3. 在 staging 啟動 DRAKVUF
4. 執行 `drakvuf --check-symbols /var/lib/drakvuf/symbols/staging`
5. 執行完整功能測試 (benchmark, process detection, syscall hook)
6. 觀察 48h 確認無 memory leak / crash

## Step 2: 生產環境部署 (窗口: 30 分鐘)
1. 停止 production DRAKVUF: `systemctl stop drakvuf@prd-vm-01`
2. 複製新的 system.map: `cp /tmp/system.map /var/lib/drakvuf/symbols/prd-vm-01/`
3. 備份舊 symbols: `cp -r /var/lib/drakvuf/symbols/prd-vm-01{,.bak}`
4. 啟動 DRAKVUF: `systemctl start drakvuf@prd-vm-01`
5. 確認 JSON output 正常: `tail -f /var/log/drakvuf/prd-vm-01.json`

## Step 3: Rollback
- 如果 DRAKVUF 無法啟動: `systemctl start drakvuf@prd-vm-01-backup` (使用舊 symbols)
- 如果 Guest OS 異常: 從 VM snapshot 恢復
```

### 6.3 日誌保留策略

```yaml
# OpenSearch ISM Policy
policies:
  - policy_id: security-events-retention
    description: Retention policy based on tier
    default_state: hot
    states:
      - name: hot
        actions:
          - rollover:
              min_size: 50gb
              min_index_age: 1d
        transitions:
          - state_name: warm
            conditions: { min_index_age: 7d }
      - name: warm
        actions: []
        transitions:
          - state_name: delete
            conditions:
              min_index_age: 365d  # Tier 0 & 2
              # min_index_age: 90d  # Tier 1
              # min_index_age: 30d  # Tier 3
      - name: delete
        actions:
          - delete: {}
```
