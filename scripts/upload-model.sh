#!/usr/bin/env bash
# =============================================================================
# upload-model.sh – Pre-populate Azure Blob Storage with a GGUF model file.
#
# Run this from your local machine or CI runner BEFORE deploying VMs if you
# want VMs to pull the model from Azure Blob Storage instead of Hugging Face.
# This avoids HF rate-limiting when many VMs download the same large file.
#
# Usage:
#   export HF_TOKEN="hf_..."
#   export HF_USERNAME="your-hf-username"
#   ./scripts/upload-model.sh \
#       --storage-account  <name> \
#       --container        model-cache \
#       --model-id         <owner/repo-gguf> \
#       --model-filename   <model-Q4_K_M.gguf> \
#       [--sas-token       <SAS>]
#
# Dependencies (on the machine running this script):
#   huggingface-hub  (pip install huggingface-hub)
#   azcopy           (https://aka.ms/downloadazcopy-v10-linux)
#   az cli           (for Managed Identity / interactive login fallback)
# =============================================================================
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
usage(){ echo "Usage: $0 --storage-account NAME --container NAME --model-id ID --model-filename FILE [--sas-token SAS] [--local-dir DIR]"; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
STORAGE_ACCOUNT=""
CONTAINER="model-cache"
MODEL_ID=""
MODEL_FILENAME=""
SAS_TOKEN=""
LOCAL_DIR="/tmp/hf-models"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage-account)  STORAGE_ACCOUNT="$2"; shift 2;;
    --container)        CONTAINER="$2";       shift 2;;
    --model-id)         MODEL_ID="$2";        shift 2;;
    --model-filename)   MODEL_FILENAME="$2";  shift 2;;
    --sas-token)        SAS_TOKEN="$2";       shift 2;;
    --local-dir)        LOCAL_DIR="$2";       shift 2;;
    --help|-h)          usage;;
    *) die "Unknown argument: $1";;
  esac
done

[[ -n "${STORAGE_ACCOUNT}" ]] || die "--storage-account is required"
[[ -n "${MODEL_ID}" ]]        || die "--model-id is required"
[[ -n "${MODEL_FILENAME}" ]]  || die "--model-filename is required"
[[ -n "${HF_TOKEN:-}" ]]      || die "HF_TOKEN environment variable is required"
[[ -n "${HF_USERNAME:-}" ]]   || die "HF_USERNAME environment variable is required"

MODEL_PATH="${LOCAL_DIR}/${MODEL_FILENAME}"

# ── Authenticate HF ───────────────────────────────────────────────────────────
log "Authenticating Hugging Face CLI..."
huggingface-cli login --token "${HF_TOKEN}" 2>/dev/null || true

# ── Download model if not already present ─────────────────────────────────────
if [[ -f "${MODEL_PATH}" ]]; then
  log "Model already present locally: ${MODEL_PATH}"
else
  mkdir -p "${LOCAL_DIR}"
  log "Downloading ${MODEL_FILENAME} from Hugging Face (${MODEL_ID})..."
  huggingface-cli download \
    --token "${HF_TOKEN}" \
    --local-dir "${LOCAL_DIR}" \
    --local-dir-use-symlinks False \
    "${MODEL_ID}" "${MODEL_FILENAME}"
  log "Download complete."
fi

log "Local model size: $(du -sh "${MODEL_PATH}" | cut -f1)"

# ── Build blob URL ────────────────────────────────────────────────────────────
if [[ -n "${SAS_TOKEN}" ]]; then
  BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${MODEL_FILENAME}?${SAS_TOKEN}"
else
  # Use Azure CLI / Managed Identity login via azcopy (OAuth).
  BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${MODEL_FILENAME}"
fi

# ── Upload to Azure Blob Storage ──────────────────────────────────────────────
log "Uploading model to Azure Blob Storage..."
log "  Source : ${MODEL_PATH}"
log "  Dest   : https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${MODEL_FILENAME}"

azcopy copy \
  "${MODEL_PATH}" \
  "${BLOB_URL}" \
  --overwrite false \
  --block-blob-tier Hot \
  --log-level INFO

log "Upload complete. Model is now available in blob storage."
log "Set STORAGE_ACCOUNT=${STORAGE_ACCOUNT} when running benchmarks to use the cache."
