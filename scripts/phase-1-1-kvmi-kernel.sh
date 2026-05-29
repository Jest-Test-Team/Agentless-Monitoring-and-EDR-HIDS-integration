#!/bin/bash
# Phase 1.1: KVMI Kernel Build & Install
# Builds a patched kernel with KVM introspection support
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_PATH="/etc/agentless/deploy.conf"
if [ -f "$CONF_PATH" ]; then
    source "$CONF_PATH"
elif [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

KVMI_REPO="https://github.com/KVM-VMI/kvm-vmi.git"
KVMI_BRANCH="linux-5.15.y"
KERNEL_VERSION="5.15.164"
BUILD_DIR="/usr/src/kvmi-kernel"
BACKUP_DIR="/boot/kernel-backups"

echo "[*] Phase 1.1: KVMI Kernel Build"
echo "========================================"

# Prerequisites
dnf groupinstall -y "Development Tools"
dnf install -y \
    git wget ncurses-devel \
    bc openssl-devel \
    elfutils-libelf-devel \
    python3-devel \
    rpm-build

# Fetch KVMI kernel
if [ ! -d "$BUILD_DIR" ]; then
    echo "[*] Cloning KVMI kernel..."
    git clone --depth 1 --branch "$KVMI_BRANCH" "$KVMI_REPO" "$BUILD_DIR"
else
    echo "[*] KVMI kernel directory exists, updating..."
    cd "$BUILD_DIR" && git pull
fi

cd "$BUILD_DIR"

# Apply KVMI patch
KVMI_PATCH="kvmi/patches/v5.15/kvm-introspection.patch"
if [ -f "$KVMI_PATCH" ]; then
    echo "[*] Applying KVMI patch..."
    patch -p1 -N < "$KVMI_PATCH" || echo "[*] Patch may already be applied"
else
    echo "[!] KVMI patch not found at $KVMI_PATCH"
    ls kvmi/patches/ 2>/dev/null || echo "No patches directory"
fi

# Configure kernel
cp /boot/config-$(uname -r) .config || cp /boot/config-* .config
make olddefconfig

# Enable KVMI & virtualization features
./scripts/config --enable KVM
./scripts/config --enable KVM_INTEL
./scripts/config --enable KVM_INTROSPECTION
./scripts/config --enable KVM_EVENTFD
./scripts/config --enable KVM_ASYNC_PF
./scripts/config --enable KVM_VFIO
./scripts/config --enable PREEMPT_VOLUNTARY
./scripts/config --set-str LOCALVERSION "-kvmi"

# Build
echo "[*] Building kernel (this may take 30-90 minutes)..."
make -j$(nproc) bzImage
make -j$(nproc) modules

# Install
echo "[*] Installing modules..."
make modules_install

echo "[*] Installing kernel..."
make install

# Backup current kernel
mkdir -p "$BACKUP_DIR"
cp /boot/vmlinuz-$(uname -r) "$BACKUP_DIR/" 2>/dev/null || true
cp /boot/System.map-$(uname -r) "$BACKUP_DIR/" 2>/dev/null || true

# Update bootloader
echo "[*] Updating GRUB..."
grub2-mkconfig -o /boot/grub2/grub.cfg

NEW_KERNEL="/boot/vmlinuz-${KERNEL_VERSION}-kvmi"
if [ -f "$NEW_KERNEL" ]; then
    grubby --set-default "$NEW_KERNEL"
    echo "[+] Default kernel set to $NEW_KERNEL"
else
    echo "[!] Could not find $NEW_KERNEL, checking alternatives..."
    ls -la /boot/vmlinuz-*kvmi*
    echo "[!] Set default manually: grubby --set-default /boot/vmlinuz-<version>-kvmi"
fi

echo "[*] Build complete. Reboot to use KVMI kernel."
echo "    After reboot, verify: lsmod | grep kvmi"
