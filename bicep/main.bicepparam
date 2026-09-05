// =============================================================================
// Default parameter values for main.bicep
// Override these to match your environment before deploying.
//
// NOTE: Hugging Face credentials (hfUsername, hfToken) and model details
// (modelFilename) are NOT Bicep parameters – they are injected at runtime
// into benchmark.sh by the workflow (Ansible env vars or Azure Run Command).
// =============================================================================
using './main.bicep'

// ---------------------------------------------------------------------------
// Required – you MUST supply these before deploying.
// ---------------------------------------------------------------------------

// Your SSH public key (RSA).  Generate with: ssh-keygen -t rsa -b 4096
// Replace the placeholder below with the full contents of your ~/.ssh/id_rsa.pub file.
param sshPublicKey = ''   // REQUIRED – leave empty string as placeholder only

// ---------------------------------------------------------------------------
// Optional – change to suit your benchmark scenario.
// ---------------------------------------------------------------------------

param location = 'eastus'   // Cobalt 100 is available in: eastus, westus3, ...

// VM SKUs to benchmark.  Comment out any SKU you lack quota for.
// Each SKU requires quota in "standardDPSv6Family" (ARM64 Cobalt 100).
// Default quotas are often low – request increases via the Azure Portal before deploying.
param vmSkus = [
  'Standard_D2ps_v6'   // 2  vCPU  –  8 GiB RAM
  'Standard_D4ps_v6'   // 4  vCPU  – 16 GiB RAM
  'Standard_D8ps_v6'   // 8  vCPU  – 32 GiB RAM
  'Standard_D16ps_v6'  // 16 vCPU  – 64 GiB RAM
  // 'Standard_D32ps_v6' // 32 vCPU – 128 GiB RAM  (requires higher quota)
]

param adminUsername = 'azureuser'

// Hugging Face model to benchmark – stored as a VM tag for reference.
// The actual download uses modelFilename, passed via benchmark.sh at runtime.
param modelId = 'unsloth/gemma-4-E4B-it-qat-GGUF'

// Azure Blob Storage for model caching.  Provide an existing storage account
// name to enable caching and avoid repeated downloads from Hugging Face.
// Leave empty to skip caching (use --sequential in the workflow in that case).
param storageAccountName  = ''
param modelCacheContainer = 'model-cache'

// OS image – ARM64 Ubuntu 22.04 LTS (matches Azure Cobalt 100 / Dps_v6 SKUs).
// For x86 SKUs (Ds_v5, etc.) change imageSku to '22_04-lts'.
param imagePublisher = 'Canonical'
param imageOffer     = '0001-com-ubuntu-server-jammy'
param imageSku       = '22_04-lts-arm64'
param osDiskSizeGB   = 128
