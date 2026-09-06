#!/usr/bin/env bash
# =============================================================================
# resolve-vm-names.sh – Convert comma-separated Azure VM SKUs to short VM names.
#
# Usage:
#   resolve-vm-names.sh "<comma-separated-skus>" [<resource-group>]
#
# Outputs:
#   GitHub Actions : writes vm_names, vm_skus_json, resource_group to $GITHUB_OUTPUT
#   Azure DevOps   : writes ##vso[task.setvariable ...] for vmNames
#
# Example:
#   resolve-vm-names.sh "Standard_D2ps_v6,Standard_D4ps_v6" "rg-ai-benchmark"
# =============================================================================
set -euo pipefail

VM_SKUS_INPUT="${1:?First argument (comma-separated SKU list) is required}"
RESOURCE_GROUP="${2:-}"

[[ -n "${RESOURCE_GROUP}" ]] || {
  echo "Resource group is required." >&2
  exit 1
}
[[ "${RESOURCE_GROUP}" =~ ^[A-Za-z0-9][-A-Za-z0-9._()]{0,89}$ ]] || {
  echo "Invalid resource group name." >&2
  exit 1
}

IFS=',' read -ra SKUS <<< "${VM_SKUS_INPUT}"

VM_NAMES=""
VM_SKUS_JSON="["
FIRST=true

for sku in "${SKUS[@]}"; do
  sku_trim="${sku// /}"
  [[ "${sku_trim}" =~ ^Standard_[A-Za-z0-9]+(_[A-Za-z0-9]+)*_v[0-9]+$ ]] || {
    echo "Invalid Azure VM SKU: ${sku_trim}" >&2
    exit 1
  }
  name="bm-$(echo "${sku_trim}" | tr '[:upper:]' '[:lower:]' | sed 's/standard_//' | tr '_' '-')"
  VM_NAMES="${VM_NAMES}${name} "
  if [[ "${FIRST}" == "true" ]]; then FIRST=false; else VM_SKUS_JSON="${VM_SKUS_JSON},"; fi
  VM_SKUS_JSON="${VM_SKUS_JSON}\"${sku_trim}\""
done

VM_NAMES="${VM_NAMES% }"   # trim trailing space
VM_SKUS_JSON="${VM_SKUS_JSON}]"

echo "VM names  : ${VM_NAMES}"
echo "SKUs JSON : ${VM_SKUS_JSON}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  # GitHub Actions mode
  #
  # azure/arm-deploy@v2 builds the az CLI command as a single string and parses
  # it with @actions/exec argStringToArray, which strips bare double-quotes.
  # A plain JSON array such as ["a","b"] therefore arrives at az as [a,b] –
  # invalid JSON.  Wrapping the value in outer double-quotes and escaping the
  # inner ones ( "[\"a\",\"b\"]" ) causes argStringToArray to treat the
  # contents as a quoted token and preserve the embedded quotes verbatim.
  VM_SKUS_JSON_ESCAPED="\"${VM_SKUS_JSON//\"/\\\"}\""
  VM_NAMES_JSON="$(echo "${VM_NAMES}" | tr ' ' '\n' | jq -R . | jq -sc .)"
  echo "vm_names=${VM_NAMES}"                   >> "${GITHUB_OUTPUT}"
  echo "vm_names_json=${VM_NAMES_JSON}"         >> "${GITHUB_OUTPUT}"
  echo "vm_skus_json=${VM_SKUS_JSON_ESCAPED}"   >> "${GITHUB_OUTPUT}"
  echo "vm_skus_json_raw=${VM_SKUS_JSON}"       >> "${GITHUB_OUTPUT}"
  [[ -n "${RESOURCE_GROUP}" ]] && echo "resource_group=${RESOURCE_GROUP}" >> "${GITHUB_OUTPUT}"
else
  # Azure DevOps mode
  echo "##vso[task.setvariable variable=vmNames;isOutput=true]${VM_NAMES}"
  echo "##vso[task.setvariable variable=vmSkusJson;isOutput=true]${VM_SKUS_JSON}"
fi
