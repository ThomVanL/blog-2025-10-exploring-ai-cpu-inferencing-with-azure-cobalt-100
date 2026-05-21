# Exploring AI CPU-Inferencing with Azure Cobalt 100

## AI CPU Benchmarking on Azure Cobalt 100

A tool repository for my [Exploring AI CPU-Inferencing with Azure Cobalt 100](https://thomasvanlaere.com/posts/2025/10/exploring-ai-cpu-inferencing-with-azure-cobalt-100/) blog post. It benchmarks AI/LLM models (phi-4, etc.) on Azure VM SKUs using **llama.cpp** for CPU-only inferencing.

> [!NOTE]
>
> Looking back at this, I probably should have used Ansible over `az vm run-command`.

There's both a **GitHub Actions workflow** and an **Azure DevOps pipeline** in there if you want to orchestrate the whole thing end-to-end. If you'd rather just grab the individual scripts in the `scripts/` folder and run them by hand, that works just fine too.

## Table of contents

- [Architecture overview](#architecture-overview)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Subscription quota](#subscription-quota)
- [Model selection](#model-selection)
- [Model caching](#model-caching)
- [Sequential vs parallel](#sequential-vs-parallel)
- [Local / manual deployment](#local--manual-deployment)
- [Azure Pipelines setup](#azure-pipelines-setup)
- [Benchmark output](#benchmark-output)
- [Links](#links)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  GitHub Actions / Azure Pipelines                   │
│                                                     │
│  1. Pre-flight  (resolve VM names from SKUs)        │
│  2. Upload Model (optional – blob cache)            │
│  3. Deploy VMs  (Bicep + AVM + deployment stack)    │
│  4. Benchmark   (Azure Run Command per VM)          │
│  5. Cleanup     (delete deployment stack)           │
└─────────────────────────────────────────────────────┘
           │                      │
           ▼                      ▼
  ┌─────────────────┐   ┌────────────────────────┐
  │  Azure          │   │  Azure Blob Storage     │
  │  Resource Group │   │  (model cache, opt.)    │
  │  ┌───────────┐  │   │  model-cache/           │
  │  │ VNet/Snet │  │   │  └ <model>.gguf         │
  │  └───────────┘  │   └────────────────────────┘
  │  ┌───────────┐  │
  │  │    LB     │──┼── public IP, NAT :5000x → SSH
  │  └─────┬─────┘  │
  │        │        │
  │  ┌─────▼─────┐  │
  │  │ bm-d2ps.. │──┼── cloud-init: llama.cpp + HF CLI
  │  │ bm-d4ps.. │  │
  │  │ bm-d8ps.. │  │   Azure Run Command injects
  │  │ bm-d16ps. │  │   benchmark.sh → captures output
  │  └───────────┘  │
  └─────────────────┘
```

**Key design choices:**

| Decision | Choice | Reason |
|---|---|---|
| Execution method | Azure Run Command (async) | No public IP / SSH needed; captured output |
| Cloud-init vs Ansible | Cloud-init | Simpler; no control node required |
| Inference engine | llama.cpp (built from source) | Native ARM/SVE optimisations for Cobalt 100 |
| Model format | GGUF (4-bit quantised) | CPU-friendly quantisation; size varies by model |
| Sequential toggle | Workflow parameter | Avoids Hugging Face download throttling |
| Model caching | Azure Blob Storage (azcopy) | Reuse model across VMs; avoids repeated HF downloads |
| Scripts | Bash only | Simple, portable, no extra runtime |

---

## Repository Structure

```
.
├── bicep/
│   ├── main.bicep          # Bicep template (resourceGroup scope, AVM modules)
│   ├── main.bicepparam     # Default parameter values
│   └── assets/
│       └── cloud-init.yaml # Cloud-init: install llama.cpp, HF CLI, azcopy
├── scripts/
│   ├── benchmark.sh        # Benchmark runner (executed ON the VM via Run Command)
│   ├── run-benchmarks.sh   # Orchestration: submit Run Commands, collect results
│   └── upload-model.sh     # Pre-upload GGUF model to Azure Blob Storage
├── .devcontainer
│   └── devcontainer.json   # Dev container configuration
├── .github/workflows/
│   └── benchmark.yml       # GitHub Actions workflow
├── .pipelines
│   └── azure-pipelines.yml # Azure Pipelines workflow
└── README.md
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Azure CLI | ≥ 2.60 | Deploy & manage resources |
| Bicep CLI | ≥ 0.28 | Compile Bicep templates |
| `huggingface-hub` | ≥ 0.22 | Download models from HF |
| AzCopy | v10 | Transfer model to/from Blob Storage |
| jq | any | Parse JSON in shell scripts |

---

## Quick Start

### 1. Configure secrets (GitHub)

In **Settings → Secrets and variables → Actions**, add:

| Secret | Description |
|---|---|
| `AZURE_CLIENT_ID` | Service principal / Managed Identity client ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `SSH_PUBLIC_KEY` | RSA public key (`ssh-keygen -t rsa -b 4096`) |
| `HF_TOKEN` | Hugging Face access token (read) |
| `HF_USERNAME` | Hugging Face username |
| `STORAGE_ACCOUNT_NAME` | *(Optional)* Azure Storage Account for model caching |
| `STORAGE_SAS_TOKEN` | *(Optional)* SAS token for the storage account |

### 2. Run the workflow

1. Go to **Actions → AI CPU Benchmark → Run workflow**
2. Fill in the parameters (resource group, location, SKUs, model, etc.)
3. Set **sequential = true** if you lack a Blob Storage cache (avoids HF throttling)
4. Click **Run workflow**

### 3. View results

- Logs are printed live in the **Run Benchmarks** job
- Results are uploaded as a workflow artifact (`benchmark-results-<run_id>`)
- Each VM produces a `<vm-name>.txt` file; a `summary.txt` aggregates JSON output

---

## Subscription Quota

> [!NOTE]
>
> ARM64 / Cobalt 100 SKUs (Standard_D*ps_v6) use a separate quota family (`standardDPSv6Family`). Default quotas are often **0** in new subscriptions.

Check and request quota increases:

```bash
# Check current quota for ARM64 Dps_v6 family
az vm list-usage --location eastus --query "[?name.localizedValue=='Standard Dpsv6 Family vCPUs']" --output table
```

Maximum vCPUs across all SKUs:

| SKU | vCPUs |
|---|---|
| Standard_D2ps_v6 | 2 |
| Standard_D4ps_v6 | 4 |
| Standard_D8ps_v6 | 8 |
| Standard_D16ps_v6 | 16 |
| Standard_D32ps_v6 | 32 |

Deploying all 4 default SKUs simultaneously: **30 vCPUs**.
The Bicep template uses `@batchSize(1)` to deploy one VM at a time, so peak
usage is the largest SKU's vCPU count (16 for the default list).

---

## Model Selection

Default model: **microsoft/phi-4-gguf** – `phi-4-Q4_K_S.gguf` (~8 GB)

Other options:

| Model | Repo | File | Size (Q4) |
|---|---|---|---|
| Phi-4 | `microsoft/phi-4-gguf` | `phi-4-Q4_K_S.gguf` | ~8 GB |
| Phi-4 | `microsoft/phi-4-gguf` | `phi-4-Q4_K_S.gguf` | ~8 GB |
| Meta-Llama-3-8B-Instruct | `QuantFactory/Meta-Llama-3-8B-Instruct-GGUF` | `Meta-Llama-3-8B-Instruct.Q4_0.gguf` | ~4 GB |

Use the model cache (Blob Storage) for models > 5 GB to avoid HF throttling.

---

## Model Caching

To avoid re-downloading a large model from Hugging Face for every VM:

1. Create an Azure Storage Account with a blob container (`model-cache`)
2. Set `STORAGE_ACCOUNT_NAME` and `STORAGE_SAS_TOKEN` secrets
3. Enable **Upload Model to Blob Storage** in the workflow
4. The first VM to encounter a cache miss will upload to blob after downloading

```bash
# Manual upload
export HF_TOKEN="hf_..."
export HF_USERNAME="your-username"

./scripts/upload-model.sh \
  --storage-account  mystorageaccount \
  --container        model-cache \
  --model-id         <owner/repo-gguf> \
  --model-filename   <model-Q4_K_M.gguf> \
  --sas-token        "sv=2022-..."
```

---

## Sequential vs Parallel

| Mode | When to use |
|---|---|
| `sequential=true` | No blob cache; limited HF bandwidth; want predictable quota usage |
| `sequential=false` | Blob cache enabled; fast benchmarks; want shorter total wall time |

---

## Local / Manual Deployment

```bash
# 1. Login
az login
az account set --subscription <id>

# 2. Create resource group
az group create --name rg-ai-benchmark --location eastus

# 3. Deploy Bicep
az deployment group create \
  --resource-group rg-ai-benchmark \
  --template-file  bicep/main.bicep \
  --parameters     bicep/main.bicepparam \
  --parameters     sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
                   modelId="<owner/repo-gguf>" \
  --name           benchmark-$(date +%s)

# 4. Run benchmarks (sequential)
chmod +x scripts/*.sh
./scripts/run-benchmarks.sh \
  --resource-group rg-ai-benchmark \
  --vm-names       "bm-d2ps-v6 bm-d4ps-v6" \
  --hf-token       "hf_..." \
  --hf-username    "your-username" \
  --model-id       "<owner/repo-gguf>" \
  --model-filename "<model-Q4_K_M.gguf>" \
  --sequential     true

# 5. Cleanup (delete deployment stack and all managed resources)
az stack group delete \
  --name           benchmark-stack \
  --resource-group rg-ai-benchmark \
  --action-on-unmanage deleteResources \
  --yes
```

---

## Azure Pipelines Setup

1. In Azure DevOps, create a **Variable group** named `ai-benchmark-secrets` with
   all the secrets listed above (plus `AZURE_SERVICE_CONNECTION`).
2. Import `.pipelines/azure-pipelines.yml` as a new pipeline.
3. Run the pipeline and fill in the parameters.

---

## Benchmark Output

Each VM produces structured output captured by Azure Run Command:

```
────────────────────────────────────────────────────────────────
[2025-10-15T12:00:00Z] === AI CPU Benchmark – System Information ===
[2025-10-15T12:00:00Z] Hostname   : bm-d8ps-v6
[2025-10-15T12:00:00Z] vCPUs      : 8
[2025-10-15T12:00:00Z] CPU model  : Neoverse-N2
...
────────────────────────────────────────────────────────────────
[2025-10-15T12:30:00Z] === Benchmark Results ===
model,size,params,backend,ngl,n_batch,n_ubatch,type_k,type_v,n_threads,test,t/s
<model-Q4_K_M.gguf>,X.XX GiB,...,CPU,0,2048,512,f16,f16,1,pp512,42.50
<model-Q4_K_M.gguf>,X.XX GiB,...,CPU,0,2048,512,f16,f16,2,pp512,82.10
<model-Q4_K_M.gguf>,X.XX GiB,...,CPU,0,2048,512,f16,f16,4,pp512,155.30
<model-Q4_K_M.gguf>,X.XX GiB,...,CPU,0,2048,512,f16,f16,8,pp512,287.90
...
BENCHMARK_JSON_START
{
  "hostname": "bm-d8ps-v6",
  "vcpus": 8,
  "arch": "aarch64",
  "model_id": "<owner/repo-gguf>",
  "results": [...]
}
BENCHMARK_JSON_END
```

Results are aggregated in `benchmark-results/summary.txt`.

---

## Links

- [Exploring AI CPU-Inferencing with Azure Cobalt 100](https://thomasvanlaere.com/posts/2025/10/exploring-ai-cpu-inferencing-with-azure-cobalt-100/) – blog post this repository accompanies
- [llama.cpp](https://github.com/ggerganov/llama.cpp) – inference engine used for benchmarking
- [microsoft/phi-4-gguf](https://huggingface.co/microsoft/phi-4-gguf) – default benchmark model on Hugging Face
- [Standard Dpsv6 series](https://learn.microsoft.com/azure/virtual-machines/dpsv6-series) – Azure Cobalt 100 VM SKU documentation
