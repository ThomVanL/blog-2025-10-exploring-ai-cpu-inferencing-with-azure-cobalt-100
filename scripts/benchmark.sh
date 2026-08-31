#!/usr/bin/env bash
# =============================================================================
# benchmark.sh – Run AI CPU inference benchmarks with llama.cpp on a single VM.
#
# This script is executed ON THE VM – via Ansible (ansible/benchmark.yml) in
# GitHub Actions, or via an Azure Run Command in Azure Pipelines.
# It is NOT meant to be run directly on your workstation.
#
# Required environment variables:
#   HF_TOKEN          – Hugging Face access token
#   HF_USERNAME       – Hugging Face username
#   MODEL_ID          – HF repo id  (e.g. microsoft/phi-4-gguf, QuantFactory/Meta-Llama-3-8B-Instruct-GGUF)
#   MODEL_FILENAME    – GGUF file   (e.g. phi-4-Q4_K_S.gguf, Meta-Llama-3-8B-Instruct.Q4_0.gguf)
#
# Optional environment variables:
#   STORAGE_ACCOUNT   – Azure Storage Account name for model caching
#   MSI_CLIENT_ID     – Client ID of the user-assigned managed identity used
#                       to authenticate AzCopy with Azure Blob Storage.
#                       If empty, Hugging Face download is used as fallback.
#   CACHE_CONTAINER   – Blob container name            (default: model-cache)
#   MODEL_DIR         – Local directory for models     (default: /opt/models)
#   THREAD_COUNTS     – Space-separated thread list    (default: 1 2 4 <nproc>)
#   BENCHMARK_TOKENS  – Tokens to generate per run     (default: 128)
#   BENCHMARK_PROMPT  – Prompt tokens to process       (default: 512)
#   BATCHED_PARALLEL  – Space-separated parallel sequence counts for
#                       llama-batched-bench             (default: 1 2 4)
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
MODEL_DIR="${MODEL_DIR:-/opt/models}"
CACHE_CONTAINER="${CACHE_CONTAINER:-model-cache}"
BENCHMARK_TOKENS="${BENCHMARK_TOKENS:-128}"
BENCHMARK_PROMPT="${BENCHMARK_PROMPT:-512}"
BATCHED_PARALLEL="${BATCHED_PARALLEL:-1 2 4 8 16}"
NCPU="$(nproc)"

# Build a default thread list: 1, 2, 4, ..., up to nproc (powers of 2).
if [[ -z "${THREAD_COUNTS:-}" ]]; then
  THREAD_COUNTS="1"
  t=2
  while (( t <= NCPU )); do
    THREAD_COUNTS="${THREAD_COUNTS} ${t}"
    t=$(( t * 2 ))
  done
  # Always include nproc if it wasn't already added.
  if [[ " ${THREAD_COUNTS} " != *" ${NCPU} "* ]]; then
    THREAD_COUNTS="${THREAD_COUNTS} ${NCPU}"
  fi
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
line() { echo "────────────────────────────────────────────────────────────────"; }

# ── Validate required inputs ──────────────────────────────────────────────────
: "${HF_TOKEN:?HF_TOKEN is required}"
: "${HF_USERNAME:?HF_USERNAME is required}"
: "${MODEL_ID:?MODEL_ID is required}"
: "${MODEL_FILENAME:?MODEL_FILENAME is required}"

MODEL_PATH="${MODEL_DIR}/${MODEL_FILENAME}"

# ── System info ───────────────────────────────────────────────────────────────
line
log "=== AI CPU Benchmark – System Information ==="
log "Hostname   : $(hostname)"
log "Kernel     : $(uname -r)"
log "CPU arch   : $(uname -m)"
log "vCPUs      : ${NCPU}"
log "CPU model  : $(grep -m1 'Model name\|model name\|CPU part' /proc/cpuinfo | sed 's/.*: *//')"
log "Total RAM  : $(awk '/MemTotal/{printf "%.1f GiB\n", $2/1024/1024}' /proc/meminfo)"
log "Model ID   : ${MODEL_ID}"
log "Model file : ${MODEL_FILENAME}"
log "Threads    : ${THREAD_COUNTS}"
line

# ── Wait for cloud-init to complete ──────────────────────────────────────────
WAIT_MAX=1800   # 30 minutes
WAIT_ELAPSED=0
log "Waiting for cloud-init to finish..."
while [[ ! -f /tmp/cloud-init-done ]]; do
  sleep 10
  WAIT_ELAPSED=$(( WAIT_ELAPSED + 10 ))
  if (( WAIT_ELAPSED >= WAIT_MAX )); then
    die "Timed out waiting for cloud-init after ${WAIT_MAX}s"
  fi
done
log "cloud-init complete."

# Confirm llama-bench is on PATH.
command -v llama-bench >/dev/null 2>&1 || die "llama-bench not found – cloud-init may have failed."

# ── Authenticate Hugging Face CLI ─────────────────────────────────────────────
log "Authenticating Hugging Face CLI..."
hf auth login --token "${HF_TOKEN}" 2>/dev/null || true

# ── Download / restore model ──────────────────────────────────────────────────
mkdir -p "${MODEL_DIR}"

download_from_hf() {
  log "Downloading ${MODEL_FILENAME} from Hugging Face (${MODEL_ID})..."
  HF_TOKEN="${HF_TOKEN}" hf download \
    --local-dir "${MODEL_DIR}" \
    "${MODEL_ID}" "${MODEL_FILENAME}"
  log "Download complete: ${MODEL_PATH}"
}

restore_from_blob() {
  local account="${1}"
  local container="${CACHE_CONTAINER}"
  local blob="${MODEL_FILENAME}"
  local url="https://${account}.blob.core.windows.net/${container}/${blob}"

  # Authenticate azcopy with the user-assigned managed identity.
  # AZCOPY_AUTO_LOGIN_TYPE=MSI tells azcopy to request a token via IMDS.
  if [[ -n "${MSI_CLIENT_ID:-}" ]]; then
    export AZCOPY_AUTO_LOGIN_TYPE=MSI
    export AZCOPY_MSI_CLIENT_ID="${MSI_CLIENT_ID}"
    log "AzCopy: using user-assigned MSI (${MSI_CLIENT_ID})"
  else
    # No MSI client ID means the VM was not provisioned with one, or the value
    # was not passed down.  AzCopy will still attempt system-assigned MSI via
    # IMDS; if that is also absent the copy will fail and the script falls back
    # to a direct Hugging Face download.
    log "WARNING: MSI_CLIENT_ID is not set. Falling back to system-assigned MSI."
    log "         If no system MSI exists on this VM, the blob download will fail"
    log "         and the model will be downloaded from Hugging Face instead."
    export AZCOPY_AUTO_LOGIN_TYPE=MSI
  fi

  log "Attempting to restore model from Azure Blob Storage (${url})..."
  if azcopy copy \
      "${url}" \
      "${MODEL_PATH}" \
      --overwrite false \
      --check-md5 FailIfDifferent \
      --log-level ERROR 2>&1; then
    log "Model restored from cache: ${MODEL_PATH}"
    return 0
  else
    log "Cache miss or download failed – will fall back to Hugging Face."
    return 1
  fi
}

if [[ -f "${MODEL_PATH}" ]]; then
  log "Model already present locally: ${MODEL_PATH}"
elif [[ -n "${STORAGE_ACCOUNT:-}" ]]; then
  restore_from_blob "${STORAGE_ACCOUNT}" || download_from_hf
else
  download_from_hf
fi

MODEL_SIZE_GiB="$(du -sh "${MODEL_PATH}" | cut -f1)"
log "Model size on disk: ${MODEL_SIZE_GiB}"

# ── Run llama-bench ───────────────────────────────────────────────────────────
# llama-bench sweeps prompt-processing (pp) and token-generation (tg) speed
# across a range of thread counts.  This mirrors the single-stream latency
# measurements from the blog post.
line
log "=== llama-bench: single-stream pp/tg speed sweep ==="
log "Prompt tokens : ${BENCHMARK_PROMPT}"
log "Output tokens : ${BENCHMARK_TOKENS}"
log "Thread sweep  : ${THREAD_COUNTS}"
line

# Build the -t arguments for every thread count we want to test.
THREAD_ARGS=""
for t in ${THREAD_COUNTS}; do
  THREAD_ARGS="${THREAD_ARGS} -t ${t}"
done

# -ngl 0       → CPU-only (no GPU offload)
# -p           → number of prompt (prefill) tokens
# -n           → number of tokens to generate
# -pg 256,1024 → mixed pp+tg scenario (pp256+tg1024), matching blog benchmarks
# --output csv → machine-readable output for downstream parsing
BENCH_OUTPUT="$(llama-bench \
  --model "${MODEL_PATH}" \
  -p "${BENCHMARK_PROMPT}" \
  -n "${BENCHMARK_TOKENS}" \
  -pg 256,1024 \
  -ngl 0 \
  ${THREAD_ARGS} \
  --output csv 2>&1)"

line
log "=== llama-bench results ==="
echo "${BENCH_OUTPUT}"
line

# ── Run llama-batched-bench ───────────────────────────────────────────────────
# llama-batched-bench measures throughput when handling multiple simultaneous
# inference requests (parallel sequences).  Relevant for multi-user / server
# scenarios on Cobalt 100.
#
# Arguments format: PP TG PL [PP TG PL ...]
#   PP – prompt tokens, TG – generation tokens, PL – parallel sequences
command -v llama-batched-bench >/dev/null 2>&1 || {
  log "WARNING: llama-batched-bench not found – skipping batched benchmark."
}

if command -v llama-batched-bench >/dev/null 2>&1; then
  line
  log "=== llama-batched-bench: multi-sequence throughput ==="
  log "Prompt     : ${BENCHMARK_PROMPT} tokens"
  log "Generation : ${BENCHMARK_TOKENS} tokens"
  log "Parallel   : ${BATCHED_PARALLEL}"
  log "Threads    : ${NCPU} (all vCPUs)"
  line

  # Build the -npl argument as a comma-separated list for llama-batched-bench.
  BATCHED_NP="$(echo "${BATCHED_PARALLEL}" | tr ' ' ',')"

  # --threads-batch  → threads used for batch processing (all vCPUs)
  # --batch-size 128 → token batch size per forward pass
  # -npp 128         → prompt tokens per sequence (fixed per blog: 128)
  # -ntg 128         → generation tokens per sequence (fixed per blog: 128)
  # -npl             → parallel sequences to test
  # --ctx-size 4096  → total KV context window; 16×(128+128)=4096 per blog
  # --flash-attn     → FlashAttention kernels for faster attention
  # --mlock          → pin model in RAM (avoids page-swap during benchmarks)
  BATCHED_OUTPUT="$(llama-batched-bench \
    --model "${MODEL_PATH}" \
    --threads "${NCPU}" \
    --threads-batch "${NCPU}" \
    --batch-size 128 \
    -npp 128 \
    -ntg 128 \
    -npl "${BATCHED_NP}" \
    --ctx-size 4096 \
    --flash-attn \
    --mlock \
    --output-format csv 2>&1)"

  line
  log "=== llama-batched-bench results ==="
  echo "${BATCHED_OUTPUT}"
  line
fi

# ── Emit structured JSON summary ──────────────────────────────────────────────
# Export CSV outputs for the Python snippet below.
export BENCH_CSV="${BENCH_OUTPUT}"
export BATCHED_OUT="${BATCHED_OUTPUT:-}"
RESULT_JSON="$(python3 - <<'PYEOF'
import sys, csv, json, io, os

raw = os.environ.get("BENCH_CSV", "")
if not raw:
    sys.exit(0)

def _parse_batched(text):
    if not text:
        return []
    try:
        reader = csv.DictReader(io.StringIO(text))
        return [row for row in reader if any(v.strip() for v in row.values())]
    except Exception:
        return []

try:
    reader = csv.DictReader(io.StringIO(raw))
    rows = [row for row in reader if any(v.strip() for v in row.values())]
    hostname = os.popen("hostname").read().strip()
    ncpu = int(os.popen("nproc").read().strip())
    cpu_model = ""
    with open("/proc/cpuinfo") as f:
        for line in f:
            if "model name" in line.lower() or "Model name" in line or "CPU part" in line:
                cpu_model = line.split(":", 1)[-1].strip()
                break
    mem_gib = round(int(open("/proc/meminfo").readline().split()[1]) / 1024 / 1024, 1)
    summary = {
        "hostname": hostname,
        "cpu_model": cpu_model,
        "vcpus": ncpu,
        "ram_gib": mem_gib,
        "arch": os.popen("uname -m").read().strip(),
        "model_id": os.environ.get("MODEL_ID", ""),
        "model_file": os.environ.get("MODEL_FILENAME", ""),
        "llama_bench": rows,
        "llama_batched_bench": _parse_batched(os.environ.get("BATCHED_OUT", "")),
    }
    print("BENCHMARK_JSON_START")
    print(json.dumps(summary, indent=2))
    print("BENCHMARK_JSON_END")
except Exception as e:
    print(f"WARNING: Could not format JSON summary: {e}", file=sys.stderr)
PYEOF
)"

echo "${RESULT_JSON}"
log "=== Benchmark complete ==="
