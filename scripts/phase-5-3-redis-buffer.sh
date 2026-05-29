#!/bin/bash
# Phase 5.3: Redis Buffer (Kafka alternative for < 10K events/sec)
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

REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_BIND="${REDIS_BIND:-0.0.0.0}"
REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-10gb}"

echo "[*] Phase 5.3: Redis Buffer Setup"
echo "========================================"

dnf install -y redis

cat > /etc/redis/redis-tier0.conf << 'RCONF'
bind 0.0.0.0
port 6379
daemonize no
supervised systemd
loglevel notice
logfile /var/log/redis/redis-tier0.log

# Memory management (10GB max, LRU eviction)
maxmemory 10gb
maxmemory-policy allkeys-lru
maxmemory-samples 10

# Persistence
save 3600 1
save 300 100
save 60 1000

# Performance
timeout 0
tcp-keepalive 300
databases 16
RCONF

systemctl enable redis@redis-tier0
systemctl start redis@redis-tier0

echo "[+] Redis buffer configured (maxmemory: 10GB, LRU)"
echo "    Verify: redis-cli ping"
