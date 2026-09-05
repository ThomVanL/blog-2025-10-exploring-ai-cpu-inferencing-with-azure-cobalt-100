#!/usr/bin/env bash
# =============================================================================
# run-benchmarks.sh – Run an AI CPU benchmark on a single Azure VM.
#
# Invokes benchmark.sh on the VM using Azure Run Command (async).
#
# Usage:
#   ./scripts/run-benchmarks.sh \
#       --resource-group   <RG> \
#       --vm-name          bm-d4ps-v6 \
#       --hf-token         <TOKEN> \
#       --hf-username      <USERNAME> \
#       --model-id         <owner/repo-gguf> \
#       --model-filename   <model-Q4_K_M.gguf> \
#       [--msi-client-id   <MSI client ID>]     (user-assigned managed identity)
#       [--storage-account <name>]
#       [--cache-container model-cache]
#       [--thread-counts   "1 2 4 8"]
#       [--benchmark-repetitions 5]
#       [--benchmark-include-mixed true|false]
#       [--benchmark-tokens 128]
#       [--benchmark-prompt 512]
#       [--batched-parallel "1 2 4"]
#       [--batched-batch-size 128]
#       [--batched-prompt-tokens 128]
#       [--batched-generation-tokens 128]
#       [--poll-interval   30]                  (seconds between status checks)
#       [--timeout         7200]                (seconds before giving up)
#       [--results-dir     ./benchmark-results]
# =============================================================================
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
line() { echo "────────────────────────────────────────────────────────────────"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
MSI_CLIENT_ID=""
STORAGE_ACCOUNT=""
CACHE_CONTAINER="model-cache"
THREAD_COUNTS=""
BENCHMARK_REPETITIONS="5"
BENCHMARK_INCLUDE_MIXED="true"
BENCHMARK_TOKENS="128"
BENCHMARK_PROMPT="512"
BATCHED_PARALLEL="1 2 4"
BATCHED_BATCH_SIZE="128"
BATCHED_PROMPT_TOKENS="128"
BATCHED_GENERATION_TOKENS="128"
POLL_INTERVAL="30"
TIMEOUT="7200"
RESULTS_DIR="./benchmark-results"
RUN_CMD_NAME="ai-benchmark-$(date -u +%Y%m%d%H%M%S)"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)     RESOURCE_GROUP="$2";    shift 2;;
    --vm-name)            VM_NAME="$2";           shift 2;;
    --hf-token)           HF_TOKEN="$2";          shift 2;;
    --hf-username)        HF_USERNAME="$2";       shift 2;;
    --model-id)           MODEL_ID="$2";          shift 2;;
    --model-filename)     MODEL_FILENAME="$2";    shift 2;;
    --msi-client-id)      MSI_CLIENT_ID="$2";     shift 2;;
    --storage-account)    STORAGE_ACCOUNT="$2";   shift 2;;
    --cache-container)    CACHE_CONTAINER="$2";   shift 2;;
    --thread-counts)      THREAD_COUNTS="$2";     shift 2;;
    --benchmark-repetitions) BENCHMARK_REPETITIONS="$2"; shift 2;;
    --benchmark-include-mixed) BENCHMARK_INCLUDE_MIXED="$2"; shift 2;;
    --benchmark-tokens)   BENCHMARK_TOKENS="$2";  shift 2;;
    --benchmark-prompt)   BENCHMARK_PROMPT="$2";  shift 2;;
    --batched-parallel)   BATCHED_PARALLEL="$2";  shift 2;;
    --batched-batch-size) BATCHED_BATCH_SIZE="$2"; shift 2;;
    --batched-prompt-tokens) BATCHED_PROMPT_TOKENS="$2"; shift 2;;
    --batched-generation-tokens) BATCHED_GENERATION_TOKENS="$2"; shift 2;;
    --poll-interval)      POLL_INTERVAL="$2";     shift 2;;
    --timeout)            TIMEOUT="$2";           shift 2;;
    --results-dir)        RESULTS_DIR="$2";       shift 2;;
    *) die "Unknown argument: $1";;
  esac
done

: "${RESOURCE_GROUP:?--resource-group is required}"
: "${VM_NAME:?--vm-name is required}"
# If --storage-account was not supplied, fall back to STORAGE_ACCOUNT_NAME env var.
# Normalize unresolved ADO macro patterns (e.g. "$(VAR)") to empty string.
if [[ -z "${STORAGE_ACCOUNT}" ]]; then
  _env_sa="${STORAGE_ACCOUNT_NAME:-}"
  if [[ "$_env_sa" != '$('* ]] && [[ "$_env_sa" != '$['* ]]; then
    STORAGE_ACCOUNT="$_env_sa"
  fi
fi
# HF credentials may come from env vars (e.g. Azure Pipelines secrets) or CLI args.
HF_TOKEN="${HF_TOKEN:-}"
HF_USERNAME="${HF_USERNAME:-}"
: "${HF_TOKEN:?HF_TOKEN env var or --hf-token is required}"
: "${HF_USERNAME:?HF_USERNAME env var or --hf-username is required}"
: "${MODEL_ID:?--model-id is required}"
: "${MODEL_FILENAME:?--model-filename is required}"

mkdir -p "${RESULTS_DIR}"

# ── Build the Run Command script ──────────────────────────────────────────────
# We inline benchmark.sh so we can pass it as a single script to Run Command.
BENCHMARK_SCRIPT="$(cat "$(dirname "$0")/benchmark.sh")"

build_env_prefix() {
  # Emit export statements consumed by benchmark.sh when run via Run Command.
  cat <<ENVEOF
export HF_TOKEN='${HF_TOKEN}'
export HF_USERNAME='${HF_USERNAME}'
export MODEL_ID='${MODEL_ID}'
export MODEL_FILENAME='${MODEL_FILENAME}'
export STORAGE_ACCOUNT='${STORAGE_ACCOUNT}'
export MSI_CLIENT_ID='${MSI_CLIENT_ID}'
export CACHE_CONTAINER='${CACHE_CONTAINER}'
export THREAD_COUNTS='${THREAD_COUNTS}'
export BENCHMARK_REPETITIONS='${BENCHMARK_REPETITIONS}'
export BENCHMARK_INCLUDE_MIXED='${BENCHMARK_INCLUDE_MIXED}'
export BENCHMARK_TOKENS='${BENCHMARK_TOKENS}'
export BENCHMARK_PROMPT='${BENCHMARK_PROMPT}'
export BATCHED_PARALLEL='${BATCHED_PARALLEL}'
export BATCHED_BATCH_SIZE='${BATCHED_BATCH_SIZE}'
export BATCHED_PROMPT_TOKENS='${BATCHED_PROMPT_TOKENS}'
export BATCHED_GENERATION_TOKENS='${BATCHED_GENERATION_TOKENS}'
ENVEOF
}

# ── Submit a Run Command to a single VM (async) ───────────────────────────────
submit_run_command() {
  local vm="$1"
  local cmd_name="${RUN_CMD_NAME}"
  log "[${vm}] Submitting async Run Command '${cmd_name}'..."

  local full_script
  full_script="$(build_env_prefix)
${BENCHMARK_SCRIPT}"

  # Write script to a temp file to avoid shell quoting issues.
  local tmp_script
  tmp_script="$(mktemp /tmp/bm-script-XXXXXX.sh)"
  echo "${full_script}" > "${tmp_script}"

  az vm run-command create \
    --resource-group "${RESOURCE_GROUP}" \
    --vm-name "${vm}" \
    --run-command-name "${cmd_name}" \
    --script "@${tmp_script}" \
    --output none

  rm -f "${tmp_script}"
  log "[${vm}] Run Command submitted."
}

# ── Wait for a Run Command to finish, then retrieve its output ────────────────
wait_and_collect() {
  local vm="$1"
  local cmd_name="${RUN_CMD_NAME}"
  local elapsed=0

  log "[${vm}] Waiting for Run Command to complete (timeout: ${TIMEOUT}s)..."
  while true; do
    local state
    state="$(az vm run-command show \
      --resource-group "${RESOURCE_GROUP}" \
      --vm-name "${vm}" \
      --run-command-name "${cmd_name}" \
      --instance-view \
      --query "instanceView.executionState" \
      --output tsv 2>/dev/null || echo "Unknown")"

    case "${state}" in
      Succeeded|Failed|TimedOut|Canceled)
        break
        ;;
    esac

    sleep "${POLL_INTERVAL}"
    elapsed=$(( elapsed + POLL_INTERVAL ))
    if (( elapsed >= TIMEOUT )); then
      log "[${vm}] WARNING: Timed out waiting for Run Command after ${TIMEOUT}s."
      break
    fi
    log "[${vm}] State: ${state} (elapsed: ${elapsed}s)"
  done

  # Retrieve output.
  local output_json
  output_json="$(az vm run-command show \
    --resource-group "${RESOURCE_GROUP}" \
    --vm-name "${vm}" \
    --run-command-name "${cmd_name}" \
    --instance-view \
    --output json)"

  local stdout stderr exec_state
  stdout="$(echo "${output_json}" | jq -r '.instanceView.output // ""')"
  stderr="$(echo "${output_json}" | jq -r '.instanceView.error  // ""')"
  exec_state="$(echo "${output_json}" | jq -r '.instanceView.executionState // "Unknown"')"

  local result_file="${RESULTS_DIR}/${vm}.txt"
  mkdir -p "${RESULTS_DIR}"
  {
    echo "=== VM: ${vm} | State: ${exec_state} ==="
    echo "--- STDOUT ---"
    echo "${stdout}"
    if [[ -n "${stderr}" ]]; then
      echo "--- STDERR ---"
      echo "${stderr}"
    fi
    echo "=== END ${vm} ==="
  } > "${result_file}"

  log "[${vm}] Run Command ${exec_state}. Results saved to ${result_file}."

  # Print result to current stdout so CI logs capture it.
  line
  cat "${result_file}"
  line
}

# ── Main orchestration ────────────────────────────────────────────────────────
line
log "Starting benchmark"
log "  Resource Group : ${RESOURCE_GROUP}"
log "  VM             : ${VM_NAME}"
log "  Model          : ${MODEL_ID} / ${MODEL_FILENAME}"
log "  Storage cache  : ${STORAGE_ACCOUNT:-disabled}"
log "  MSI client ID  : ${MSI_CLIENT_ID:-not set}"
line

submit_run_command "${VM_NAME}"
wait_and_collect "${VM_NAME}"

log "Benchmark complete."
