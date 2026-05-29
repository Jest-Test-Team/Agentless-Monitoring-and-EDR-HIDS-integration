#!/bin/bash
# build-offline-bundle.sh — Build air-gapped deployment bundle
# Downloads all RPMs, scripts, and configs into a portable tarball
# for deployment on air-gapped / disconnected networks
set -euo pipefail

VERSION="${1:-1.0.0}"
OUTPUT_DIR="${2:-/tmp/agentless-offline}"
BUNDLE_NAME="agentless-offline-${VERSION}.tar.gz"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[*] Building offline bundle v${VERSION}"
echo "  Output: ${OUTPUT_DIR}/${BUNDLE_NAME}"
echo "================================================"

mkdir -p "$OUTPUT_DIR"

# Phase 1: Download RPMs for all components
echo "[*] Downloading RPMs..."
RPM_DIR="${OUTPUT_DIR}/rpms"
mkdir -p "$RPM_DIR"

download_rpm() {
    local pkg="$1" url="$2"
    echo "  Downloading: $pkg"
    curl -sL -o "$RPM_DIR/${pkg}.rpm" "$url" || echo "  [WARN] Failed to download $pkg"
}

# Wazuh agent (x86_64)
download_rpm "wazuh-agent" "https://packages.wazuh.com/4.x/yum/wazuh-agent-4.9.0-1.x86_64.rpm"
# Osquery
download_rpm "osquery" "https://pkg.osquery.io/rpm/osquery-5.12.0-1.linux.x86_64.rpm"
# Suricata
download_rpm "suricata" "https://copr-be.cloud.fedoraproject.org/results/jmal濛/suricata/epel-9-x86_64/suricata-7.0.3-1.el9.x86_64.rpm" || true
# Filebeat
download_rpm "filebeat" "https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-7.17.24-x86_64.rpm"
# Logstash
download_rpm "logstash" "https://artifacts.elastic.co/downloads/logstash/logstash-7.17.24-x86_64.rpm" || true
# Redis
download_rpm "redis" "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/r/redis-7.2.4-1.el9.x86_64.rpm" || true
# AIDE
download_rpm "aide" "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/a/aide-0.18.6-1.el9.x86_64.rpm" || true

# Phase 2: Copy scripts
echo "[*] Copying scripts..."
SCRIPT_DIR="${OUTPUT_DIR}/scripts"
mkdir -p "$SCRIPT_DIR"
cp "$REPO_ROOT/scripts/"*.sh "$REPO_ROOT/scripts/"*.py "$SCRIPT_DIR/" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/"*.sh "$SCRIPT_DIR/"*.py 2>/dev/null || true

# Phase 3: Copy configs
echo "[*] Copying configs..."
CONFIG_DIR="${OUTPUT_DIR}/configs"
mkdir -p "$CONFIG_DIR"
if [ -d "$REPO_ROOT/configs" ]; then
    cp -r "$REPO_ROOT/configs/"* "$CONFIG_DIR/" 2>/dev/null || true
fi

# Phase 4: Copy Ansible playbooks
echo "[*] Copying Ansible playbooks..."
ANSIBLE_DIR="${OUTPUT_DIR}/ansible"
if [ -d "$REPO_ROOT/ansible" ]; then
    cp -r "$REPO_ROOT/ansible" "$ANSIBLE_DIR"
fi

# Phase 5: Copy docs
echo "[*] Copying docs..."
DOCS_DIR="${OUTPUT_DIR}/docs"
mkdir -p "$DOCS_DIR"
cp "$REPO_ROOT/docs/"*.md "$DOCS_DIR/" 2>/dev/null || true

# Phase 6: Generate install script for offline use
cat > "${OUTPUT_DIR}/install-offline.sh" << 'INSTALL'
#!/bin/bash
# Offline installer — run on air-gapped target host
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo " Agentless Offline Installer"
echo "============================================"
echo ""

# Verify root
if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root" >&2
    exit 1
fi

# Install RPMs
echo "[*] Installing RPMs..."
rpm -ivh "$SCRIPT_DIR/rpms/"*.rpm 2>/dev/null || {
    echo "[!] Some RPMs failed (dependencies may need --nodeps)"
    echo "    Run: rpm -ivh --nodeps $SCRIPT_DIR/rpms/*.rpm"
}

# Copy scripts
echo "[*] Installing scripts..."
cp "$SCRIPT_DIR/scripts/"*.sh /usr/local/bin/ 2>/dev/null || true
cp "$SCRIPT_DIR/scripts/"*.py /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/*.sh /usr/local/bin/*.py 2>/dev/null || true

# Copy configs
echo "[*] Installing configs..."
if [ -d "$SCRIPT_DIR/../configs" ]; then
    cp -r "$SCRIPT_DIR/../configs/"* /etc/agentless/ 2>/dev/null || true
fi

echo "[+] Offline install complete"
echo "    Run deploy-all.sh to deploy specific tier"
INSTALL
chmod +x "${OUTPUT_DIR}/install-offline.sh"

# Build tarball
echo "[*] Creating bundle..."
cd "$OUTPUT_DIR"
tar czf "$BUNDLE_NAME" \
    rpms/ scripts/ configs/ ansible/ docs/ install-offline.sh 2>/dev/null || {
    tar czf "$BUNDLE_NAME" \
        rpms/ scripts/ configs/ docs/ install-offline.sh 2>/dev/null || true
}

echo ""
echo "================================================"
echo " Bundle: ${OUTPUT_DIR}/${BUNDLE_NAME}"
echo " Size:   $(du -h "$BUNDLE_NAME" | cut -f1)"
echo " Usage:"
echo "   1. Copy tarball to air-gapped host"
echo "   2. tar xzf ${BUNDLE_NAME}"
echo "   3. sudo ./install-offline.sh"
echo "================================================"
