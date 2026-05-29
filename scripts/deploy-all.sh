#!/bin/bash
# deploy-all.sh — Master Deployment Orchestrator
# Runs all phase scripts in the correct order for a given tier
# Supports Ansible mode (default) or local script mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_PATH="/etc/agentless/deploy.conf"
if [ -f "$CONF_PATH" ]; then
    source "$CONF_PATH"
elif [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

MODE="${1:-local}"       # local | ansible
TIER="${2:-tier0}"       # tier0 | tier1 | tier2 | tier3
ANSIBLE_DIR="$SCRIPT_DIR/../ansible"

usage() {
    echo "Usage: $0 [local|ansible] [tier0|tier1|tier2|tier3]"
    echo ""
    echo "Modes:"
    echo "  local   Run phase scripts sequentially on this host (default)"
    echo "  ansible Run Ansible playbook for the specified tier"
    echo ""
    echo "Examples:"
    echo "  $0 local tier0     # Run all Tier 0 scripts on this host"
    echo "  $0 ansible tier0   # Run Ansible for all Tier 0 hosts"
    exit 1
}

deploy_local_tier0() {
    echo "=== Deploying Tier 0 (DRAKVUF + NIDS) ==="
    $SCRIPT_DIR/phase-0-check.sh
    $SCRIPT_DIR/phase-1-1-kvmi-kernel.sh
    $SCRIPT_DIR/phase-1-2-host-hardening.sh
    $SCRIPT_DIR/phase-1-3-dom0-monitoring.sh
    $SCRIPT_DIR/phase-2-1-drakvuf-install.sh
    $SCRIPT_DIR/phase-2-2-drakvuf-config.sh
    $SCRIPT_DIR/phase-2-4-port-mirror.sh
    $SCRIPT_DIR/phase-3-suricata.sh
    $SCRIPT_DIR/phase-5-1-filebeat.sh
    echo "=== Tier 0 deployment complete ==="
}

deploy_local_tier1() {
    echo "=== Deploying Tier 1 (Wazuh + Osquery + Auditd) ==="
    $SCRIPT_DIR/phase-4-wazuh-deploy.sh "${WAZUH_MANAGER:-10.0.0.30}" tier1
    cp "$SCRIPT_DIR/../configs/auditd/rules.d/tier1-audit.rules" /etc/audit/rules.d/
    augenrules --load
    $SCRIPT_DIR/run-risk-scanner.sh --quick
    echo "=== Tier 1 deployment complete ==="
}

deploy_local_tier2() {
    echo "=== Deploying Tier 2 (Bare metal HIDS) ==="
    $SCRIPT_DIR/phase-4-wazuh-deploy.sh "${WAZUH_MANAGER:-10.0.0.30}" tier2
    cp "$SCRIPT_DIR/../configs/auditd/rules.d/tier2-audit.rules" /etc/audit/rules.d/
    augenrules --load
    cp "$SCRIPT_DIR/../configs/aide/aide.conf" /etc/aide.conf
    aide --init
    $SCRIPT_DIR/phase-2-5-nftables-log.sh
    $SCRIPT_DIR/run-risk-scanner.sh --all
    echo "=== Tier 2 deployment complete ==="
}

deploy_local_tier3() {
    echo "=== Deploying Tier 3 (Dev/test lightweight) ==="
    $SCRIPT_DIR/phase-4-wazuh-deploy.sh "${WAZUH_MANAGER:-10.0.0.30}" tier3
    INSTALL_WAZUH=no $SCRIPT_DIR/phase-4-1-rsyslog-tier3.sh
    echo "=== Tier 3 deployment complete ==="
}

deploy_ansible() {
    local tier="$1"
    echo "=== Deploying $tier via Ansible ==="
    if [ ! -d "$ANSIBLE_DIR" ]; then
        echo "Ansible directory not found: $ANSIBLE_DIR"
        exit 1
    fi
    cd "$ANSIBLE_DIR"
    if [ "$tier" = "all" ]; then
        ansible-playbook -i inventory/hosts.ini site.yml
    else
        ansible-playbook -i inventory/hosts.ini site.yml --limit "$tier"
    fi
}

case "$MODE" in
    local)
        case "$TIER" in
            tier0) deploy_local_tier0 ;;
            tier1) deploy_local_tier1 ;;
            tier2) deploy_local_tier2 ;;
            tier3) deploy_local_tier3 ;;
            *) usage ;;
        esac
        ;;
    ansible)
        deploy_ansible "$TIER"
        ;;
    *)
        usage
        ;;
esac

echo "[+] Deployment completed for $TIER ($MODE mode)"
