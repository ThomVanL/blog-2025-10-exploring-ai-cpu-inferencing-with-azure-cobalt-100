#!/usr/bin/env bash
# =============================================================================
# build-skus-json.sh – Convert a comma-separated VM SKU list to a JSON array
#                      and optionally emit it as an Azure DevOps pipeline variable.
#
# Usage:
#   build-skus-json.sh "<comma-separated-skus>"
#
# Output:
#   Prints the JSON array to stdout.
#   Azure DevOps: also sets the pipeline variable vmSkusJson.
#
# Example:
#   build-skus-json.sh "Standard_D2ps_v6,Standard_D4ps_v6"
#   # prints: ["Standard_D2ps_v6","Standard_D4ps_v6"]
# =============================================================================
set -euo pipefail

VM_SKUS_INPUT="${1:?First argument (comma-separated SKU list) is required}"

IFS=',' read -ra SKUS <<< "${VM_SKUS_INPUT}"

JSON="["
FIRST=true
for sku in "${SKUS[@]}"; do
  sku_trim="${sku// /}"
  if [[ "${FIRST}" == "true" ]]; then FIRST=false; else JSON="${JSON},"; fi
  JSON="${JSON}\"${sku_trim}\""
done
JSON="${JSON}]"

echo "SKUs JSON: ${JSON}"
echo "##vso[task.setvariable variable=vmSkusJson]${JSON}"
