#!/bin/bash
# Phase 2.1: DRAKVUF & LibVMI Build/Install
set -euo pipefail

LIBVMI_REPO="https://github.com/libvmi/libvmi.git"
DRAKVUF_REPO="https://github.com/tklengyel/drakvuf.git"
INSTALL_PREFIX="/usr/local"

echo "[*] Phase 2.1: DRAKVUF + LibVMI Installation"
echo "================================================"

# Prerequisites
dnf install -y \
    cmake make gcc gcc-c++ \
    autoconf automake libtool \
    json-c-devel \
    libvirt-devel \
    glib2-devel \
    glibc-devel \
    pkgconfig \
    python3 python3-pip \
    libpng-devel \
    libwebsockets-devel

# Build LibVMI
echo "[*] Building LibVMI..."
if [ -d /usr/src/libvmi ]; then
    cd /usr/src/libvmi && git pull
else
    git clone --depth 1 "$LIBVMI_REPO" /usr/src/libvmi
    cd /usr/src/libvmi
fi

autoreconf -i
./configure --enable-kvm --prefix="$INSTALL_PREFIX"
make -j$(nproc)
make install
ldconfig

echo "[+] LibVMI installed"

# Build DRAKVUF
echo "[*] Building DRAKVUF..."
if [ -d /usr/src/drakvuf ]; then
    cd /usr/src/drakvuf && git pull
else
    git clone --depth 1 --recursive "$DRAKVUF_REPO" /usr/src/drakvuf
    cd /usr/src/drakvuf
fi

mkdir -p build && cd build
cmake .. \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DENABLE_XEN=OFF \
    -DENABLE_KVM=ON
make -j$(nproc)
make install

echo "[+] DRAKVUF installed"

# Verify
echo "[*] Verifying installation..."
"$INSTALL_PREFIX/bin/drakvuf" --version

# Create config & data directories
mkdir -p /etc/drakvuf
mkdir -p /var/log/drakvuf
mkdir -p /var/lib/drakvuf/symbols

echo "[*] Installation complete."
echo "    Run: phase-2-2-drakvuf-config.sh to configure"
