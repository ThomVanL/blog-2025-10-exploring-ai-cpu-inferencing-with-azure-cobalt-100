#!/usr/bin/env bash
# =============================================================================
# build-ansible-inventory.sh – Generate an Ansible inventory for benchmark VMs.
#
# Resolves the load balancer public IP and the per-VM inbound SSH NAT port
# (deployed by bicep/main.bicep) so the Ansible control node (e.g. a GitHub
# Actions runner) can reach each VM over SSH.
#
# Usage:
#   ./scripts/build-ansible-inventory.sh \
#       --resource-group  <RG> \
#       --vm-names        "bm-d2ps-v6 bm-d4ps-v6" \
#       [--admin-username azureuser] \
#       [--private-key    ~/.ssh/id_rsa] \
#       [--inventory-file ./inventory.ini]
#
# Requires: az (logged in)
# =============================================================================
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }
require_value() {
  [[ $# -ge 2 ]] || die "$1 requires a value"
}

# ── Defaults ──────────────────────────────────────────────────────────────────
ADMIN_USERNAME="azureuser"
PRIVATE_KEY=""
INVENTORY_FILE="./inventory.ini"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      require_value "$@"
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --vm-names)
      require_value "$@"
      VM_NAMES="$2"
      shift 2
      ;;
    --admin-username)
      require_value "$@"
      ADMIN_USERNAME="$2"
      shift 2
      ;;
    --private-key)
      require_value "$@"
      PRIVATE_KEY="$2"
      shift 2
      ;;
    --inventory-file)
      require_value "$@"
      INVENTORY_FILE="$2"
      shift 2
      ;;
    *) die "Unknown argument: $1";;
  esac
done

: "${RESOURCE_GROUP:?--resource-group is required}"
: "${VM_NAMES:?--vm-names is required}"

# ── Resolve the LB public IP deployed by bicep/main.bicep ─────────────────────
LB_PUBLIC_IP="$(az network public-ip list \
  --resource-group "${RESOURCE_GROUP}" \
  --query "[?starts_with(name, 'pip-bm-ssh-')].ipAddress | [0]" \
  --output tsv)"
[[ -n "${LB_PUBLIC_IP}" && "${LB_PUBLIC_IP}" != "None" ]] \
  || die "Could not resolve LB public IP (pip-bm-ssh-*) in ${RESOURCE_GROUP}."

log "Load balancer public IP: ${LB_PUBLIC_IP}"

# ── Resolve the SSH NAT frontend port for a single VM ─────────────────────────
resolve_ssh_port() {
  local vm="$1"

  local nic_id
  nic_id="$(az vm show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${vm}" \
    --query "networkProfile.networkInterfaces[0].id" \
    --output tsv)"
  [[ -n "${nic_id}" ]] || die "Could not resolve NIC for VM ${vm}."

  local nat_rule_id
  nat_rule_id="$(az network nic show \
    --ids "${nic_id}" \
    --query "ipConfigurations[0].loadBalancerInboundNatRules[0].id" \
    --output tsv)"
  [[ -n "${nat_rule_id}" && "${nat_rule_id}" != "None" ]] \
    || die "VM ${vm} has no inbound SSH NAT rule."

  local port
  port="$(az resource show \
    --ids "${nat_rule_id}" \
    --query "properties.frontendPort" \
    --output tsv)"
  [[ -n "${port}" ]] || die "Could not resolve frontend port for VM ${vm}."

  echo "${port}"
}

# ── Write the inventory ───────────────────────────────────────────────────────
mkdir -p "$(dirname "${INVENTORY_FILE}")"
{
  echo "[benchmark]"
  for vm in ${VM_NAMES}; do
    port="$(resolve_ssh_port "${vm}")"
    log "  ${vm} → ${LB_PUBLIC_IP}:${port}" >&2
    line="${vm} ansible_host=${LB_PUBLIC_IP} ansible_port=${port} ansible_user=${ADMIN_USERNAME}"
    if [[ -n "${PRIVATE_KEY}" ]]; then
      line="${line} ansible_ssh_private_key_file=${PRIVATE_KEY}"
    fi
    echo "${line}"
  done
} > "${INVENTORY_FILE}"

log "Inventory written to ${INVENTORY_FILE}:"
cat "${INVENTORY_FILE}"
