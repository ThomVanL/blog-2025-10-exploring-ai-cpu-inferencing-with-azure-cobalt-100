// =============================================================================
// AI CPU Benchmarking – Azure Cobalt 100 (ARM64)
// Scope : Resource Group
// Deploys one Linux VM per SKU, installs llama.cpp via cloud-init,
// then benchmarks a Hugging Face GGUF model at runtime (Ansible over SSH
// in GitHub Actions; Azure Run Command in Azure Pipelines).
// =============================================================================
targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('''Array of Azure VM SKUs to benchmark.
NOTE: Ensure your subscription has sufficient vCPU quota for every SKU listed.
  ARM64 (Cobalt 100) SKUs  → "standardDPSv6Family" quota family.
  x86 SKUs (Ds_v5, etc.)  → "standardDSv5Family" quota family.
Remove or comment out SKUs you do not have quota for before deploying.
''')
param vmSkus array = [
  'Standard_D2ps_v6'
  'Standard_D4ps_v6'
  'Standard_D8ps_v6'
  'Standard_D16ps_v6'
  'Standard_D32ps_v6'
]

@description('Admin username for the benchmark VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key (RSA) used for VM authentication. Paste the full key string.')
param sshPublicKey string

@description('''
Hugging Face model repository ID (owner/repo-name) used only for tagging VMs.
The actual model download is performed by benchmark.sh at runtime.
''')
param modelId string = 'unsloth/gemma-4-E4B-it-qat-GGUF'

@description('''
Name of an existing Azure Storage Account used to cache the downloaded GGUF model.
When provided, a user-assigned managed identity on the VMs is granted
Storage Blob Data Reader access so VMs can pull the model without a SAS token.
Leave empty ("") to disable blob caching.
''')
param storageAccountName string = ''

@description('Blob container name used to store cached GGUF model files.')
param modelCacheContainer string = 'model-cache'

@description('OS image publisher.')
param imagePublisher string = 'Canonical'

@description('OS image offer. Use "0001-com-ubuntu-server-jammy" for Ubuntu 22.04 LTS.')
param imageOffer string = '0001-com-ubuntu-server-jammy'

@description('OS image SKU. Use "22_04-lts-arm64" for ARM64 (Cobalt 100); "22_04-lts" for x86_64.')
param imageSku string = '22_04-lts-arm64'

@description('OS disk size in GiB. Models are large – 128 GiB minimum recommended.')
param osDiskSizeGB int = 128

// ─── Variables ────────────────────────────────────────────────────────────────

// 8-char suffix that is unique per (resource-group, deployment-name) pair.
// This keeps every module deployment name globally unique and allows concurrent
// benchmark deployments in the same subscription without name collisions.
var deploymentSuffix = take(uniqueString(resourceGroup().id, deployment().name), 8)

// Derives a short, DNS-safe VM name from the SKU string.
// "Standard_D4ps_v6" → "bm-d4ps-v6"  (prefix "bm" = benchmark)
var vmNames = [
  for sku in vmSkus: 'bm-${replace(replace(toLower(sku), 'standard_', ''), '_', '-')}'
]

// Storage Blob Data Reader built-in role definition ID.
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// SSH inbound NAT rules — one per VM, mapping LB port 50001+i → VM port 22.
var sshNatRules = [
  for (sku, i) in vmSkus: {
    name: 'ssh-nat-${i}'
    frontendIPConfigurationName: 'fe-benchmark'
    frontendPort: 50001 + i
    backendPort: 22
    protocol: 'Tcp'
    enableTcpReset: true
    idleTimeoutInMinutes: 4
  }
]

// ─── User-Assigned Managed Identity ──────────────────────────────────────────
// All benchmark VMs share one user-assigned managed identity so that azcopy
// can authenticate with Blob Storage without SAS tokens.

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'id-benchmark-${deploymentSuffix}'
  params: {
    name: 'id-bm-${deploymentSuffix}'
    location: location
    tags: {
      purpose: 'ai-benchmark'
    }
  }
}

// ─── Blob reader role assignment (conditional on storage account) ─────────────
// Grant the managed identity Storage Blob Data Reader on the cache storage
// account so benchmark VMs can pull models without a SAS token.

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (!empty(storageAccountName)) {
  // When storageAccountName is empty the condition prevents this resource from
  // being looked up, but Bicep still evaluates the 'name' property at compile
  // time, so a non-empty placeholder string is required to satisfy the type
  // system.  The role assignment below is also gated on the same condition and
  // will not be created when storageAccountName is empty.
  name: !empty(storageAccountName) ? storageAccountName : 'placeholder-unused'
}

resource blobReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(storageAccountName)) {
  scope: storageAccount
  name: guid(resourceGroup().id, storageAccountName, storageBlobDataReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Network Security Group ───────────────────────────────────────────────────
// Allows inbound SSH from the Internet so the load balancer NAT rules can
// forward traffic to each VM on port 22. Applied at subnet level.

module nsg 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'nsg-benchmark-${deploymentSuffix}'
  params: {
    name: 'nsg-benchmark-${deploymentSuffix}'
    location: location
    securityRules: [
      {
        name: 'allow-ssh-inbound'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'allow-internet-outbound'
        properties: {
          priority: 100
          protocol: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
    tags: {
      purpose: 'ai-benchmark'
    }
  }
}

// ─── Networking ───────────────────────────────────────────────────────────────

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.4.0' = {
  name: 'vnet-benchmark-${deploymentSuffix}'
  params: {
    name: 'vnet-benchmark-${deploymentSuffix}'
    location: location
    addressPrefixes: ['10.10.0.0/16']
    subnets: [
      {
        name: 'snet-benchmark'
        addressPrefix: '10.10.0.0/24'
        networkSecurityGroupResourceId: nsg.outputs.resourceId
        defaultOutboundAccess: true
      }
    ]
    tags: {
      purpose: 'ai-benchmark'
    }
  }
}

// ─── Load Balancer ────────────────────────────────────────────────────────────
// Standard LB with one shared public IP. Each VM gets a dedicated inbound NAT
// rule so SSH is reachable at <lbPublicIp>:50001+i — a cost-effective
// alternative to Azure Bastion Standard.

resource lbPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-bm-ssh-${deploymentSuffix}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  tags: { purpose: 'ai-benchmark' }
}

module loadBalancer 'br/public:avm/res/network/load-balancer:0.4.0' = {
  name: 'lb-bm-${deploymentSuffix}'
  params: {
    name: 'lb-bm-${deploymentSuffix}'
    location: location
    skuName: 'Standard'
    frontendIPConfigurations: [
      {
        name: 'fe-benchmark'
        publicIPAddressId: lbPublicIp.id
      }
    ]
    backendAddressPools: [
      { name: 'bep-benchmark' }
    ]
    inboundNatRules: sshNatRules
    outboundRules: [
      {
        name: 'outbound-internet'
        frontendIPConfigurationName: 'fe-benchmark'
        backendAddressPoolName: 'bep-benchmark'
        protocol: 'All'
        allocatedOutboundPorts: 10000
        idleTimeoutInMinutes: 4
        enableTcpReset: false
      }
    ]
    tags: {
      purpose: 'ai-benchmark'
    }
  }
}

// ─── VMs ─────────────────────────────────────────────────────────────────────
// One VM per SKU.  @batchSize(1) deploys VMs one at a time, which keeps vCPU
// consumption predictable and avoids breaching subscription quota limits.
// Remove @batchSize(1) to deploy all VMs concurrently (faster, but requires
// having full quota available simultaneously).
@batchSize(1)
module vm 'br/public:avm/res/compute/virtual-machine:0.12.0' = [
  for (sku, i) in vmSkus: {
    // Deployment name must be unique per invocation and per SKU index.
    name: 'vm-bm-${i}-${deploymentSuffix}'
    params: {
      name: vmNames[i]
      location: location
      zone: 0
      adminUsername: adminUsername

      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: 'latest'
      }

      nicConfigurations: [
        {
          ipConfigurations: [
            {
              name: 'ipconfig1'
              subnetResourceId: '${virtualNetwork.outputs.resourceId}/subnets/snet-benchmark'
              privateIPAllocationMethod: 'Dynamic'
              loadBalancerBackendAddressPools: [
                { id: '${loadBalancer.outputs.resourceId}/backendAddressPools/bep-benchmark' }
              ]
              loadBalancerInboundNatRules: [
                { id: '${loadBalancer.outputs.resourceId}/inboundNatRules/ssh-nat-${i}' }
              ]
            }
          ]
          nicSuffix: '-nic'
          deleteOption: 'Delete'
        }
      ]

      osDisk: {
        caching: 'ReadWrite'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: osDiskSizeGB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }

      osType: 'Linux'
      vmSize: sku
      disablePasswordAuthentication: true
      publicKeys: [
        {
          keyData: sshPublicKey
          path: '/home/${adminUsername}/.ssh/authorized_keys'
        }
      ]

      // Cloud-init is injected as customData. The AVM module base64-encodes
      // this value internally before sending to the ARM API, so plain text
      // must be passed here (loadTextContent, NOT loadFileAsBase64).
      customData: loadTextContent('assets/cloud-init.yaml')

      // Attach user-assigned managed identity so azcopy can authenticate
      // with Azure Blob Storage without a SAS token.
      managedIdentities: {
        userAssignedResourceIds: [identity.outputs.resourceId]
      }

      tags: {
        purpose: 'ai-benchmark'
        modelId: modelId
        vmSku: sku
      }
    }
  }
]

// ─── Outputs ─────────────────────────────────────────────────────────────────

@description('Names of deployed benchmark VMs (one per SKU).')
output vmNamesOutput array = vmNames

@description('Resource group name (useful for scripting).')
output resourceGroupName string = resourceGroup().name

@description('Storage account name used for model caching (empty if disabled).')
output storageAccountName string = storageAccountName

@description('Blob container name for cached models.')
output modelCacheContainer string = modelCacheContainer

@description('Client ID of the user-assigned managed identity attached to benchmark VMs. Pass this to benchmark.sh as MSI_CLIENT_ID so azcopy can authenticate with Blob Storage.')
output identityClientId string = identity.outputs.clientId

@description('Resource ID of the user-assigned managed identity.')
output identityResourceId string = identity.outputs.resourceId

@description('Name of the user-assigned managed identity (used by cleanup to delete it explicitly).')
output identityName string = identity.outputs.name

@description('Name of the virtual network deployed for the benchmark VMs (used by cleanup to delete it explicitly).')
output vnetName string = virtualNetwork.outputs.name

@description('Name of the load balancer fronting the benchmark VMs.')
output lbName string = loadBalancer.outputs.name

@description('Name of the NSG applied to the benchmark subnet.')
output nsgName string = nsg.outputs.name

@description('Name of the LB public IP resource (query with: az network public-ip show -g <rg> -n <name> --query ipAddress).')
output lbPublicIpName string = lbPublicIp.name

@description('Public IP address of the load balancer. SSH into each VM via: ssh -i <key> -p <sshPort> azureuser@<lbPublicIpAddress>')
output lbPublicIpAddress string = lbPublicIp.properties.ipAddress

@description('Per-VM SSH port mapping on the LB public IP. Port 50001 = VM index 0, 50002 = VM index 1, etc.')
output sshPortMap array = [
  for (sku, i) in vmSkus: {
    vmName: vmNames[i]
    sshPort: 50001 + i
  }
]
