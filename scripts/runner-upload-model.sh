#!/usr/bin/env bash
# =============================================================================
# runner-upload-model.sh – Runner-side wrapper: install dependencies and upload
#                          a GGUF model to Azure Blob Storage.
#
# Intended to be called from an Azure Pipelines AzureCLI@2 task with
# scriptLocation: scriptPath.  The AzureCLI@2 task provides Azure CLI
# credentials automatically so azcopy can use CLI-based authentication.
#
# Required environment variables (set as task env or pipeline variables):
#   HF_TOKEN             – Hugging Face access token
#   HF_USERNAME          – Hugging Face username
#   STORAGE_ACCOUNT_NAME – Azure Storage Account name
#   MODEL_ID             – HF model repository ID
#   MODEL_FILENAME       – GGUF filename
#
# Optional environment variables:
#   CACHE_CONTAINER      – Blob container (default: model-cache)
# =============================================================================
set -euo pipefail

: "${HF_TOKEN:?HF_TOKEN is required}"
: "${HF_USERNAME:?HF_USERNAME is required}"
: "${STORAGE_ACCOUNT_NAME:?STORAGE_ACCOUNT_NAME is required}"
: "${MODEL_ID:?MODEL_ID is required}"
: "${MODEL_FILENAME:?MODEL_FILENAME is required}"
CACHE_CONTAINER="${CACHE_CONTAINER:-model-cache}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install Python dependency for HF CLI
pip install --upgrade huggingface-hub --quiet

# Delegate to the main upload script
bash "${SCRIPT_DIR}/upload-model.sh" \
  --storage-account "${STORAGE_ACCOUNT_NAME}" \
  --container       "${CACHE_CONTAINER}" \
  --model-id        "${MODEL_ID}" \
  --model-filename  "${MODEL_FILENAME}"
