#!/usr/bin/env bash
# Configure the Azure DevOps variable group used by azure-pipelines.yml.
#
# This script creates or updates the benchmark variable group. It does not
# create an Azure service connection; create that in Azure DevOps first and
# pass its name with --service-connection.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-azure-devops.sh --organization URL --project NAME \
    --service-connection NAME --ssh-public-key FILE --ssh-private-key FILE \
    [options]

Required:
  --organization URL       Azure DevOps organization URL
  --project NAME           Azure DevOps project name
  --service-connection NAME
                           Existing Azure service connection name
  --ssh-public-key FILE    Public key provisioned on benchmark VMs
  --ssh-private-key FILE   Matching private key used by Ansible

Options:
  --group-name NAME        Variable group name (default: ai-benchmark-secrets)
  --hf-token-env NAME      Environment variable containing the HF token
                           (default: HF_TOKEN)
  --hf-username-env NAME   Environment variable containing the HF username
                           (default: HF_USERNAME)
  --storage-account NAME   Optional Azure Storage account name
  --storage-account-env NAME
                           Environment variable containing the storage name
  --allow-existing-group   Update an existing group instead of failing
  -h, --help               Show this help

Example:
  HF_TOKEN=hf_... HF_USERNAME=your-user \
  scripts/setup-azure-devops.sh \
    --organization https://dev.azure.com/ORG \
    --project ado-sandbox \
    --service-connection ado-sbx \
    --ssh-public-key ~/.ssh/adovm.pub \
    --ssh-private-key ~/.ssh/adovm
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ORGANIZATION=""
PROJECT=""
SERVICE_CONNECTION=""
GROUP_NAME="ai-benchmark-secrets"
SSH_PUBLIC_KEY_FILE=""
SSH_PRIVATE_KEY_FILE=""
HF_TOKEN_ENV="HF_TOKEN"
HF_USERNAME_ENV="HF_USERNAME"
STORAGE_ACCOUNT=""
STORAGE_ACCOUNT_ENV="STORAGE_ACCOUNT_NAME"
ALLOW_EXISTING_GROUP=false

while (($# > 0)); do
  case "$1" in
    --organization) [[ $# -ge 2 ]] || die "$1 requires a value"; ORGANIZATION="$2"; shift 2 ;;
    --project) [[ $# -ge 2 ]] || die "$1 requires a value"; PROJECT="$2"; shift 2 ;;
    --service-connection) [[ $# -ge 2 ]] || die "$1 requires a value"; SERVICE_CONNECTION="$2"; shift 2 ;;
    --group-name) [[ $# -ge 2 ]] || die "$1 requires a value"; GROUP_NAME="$2"; shift 2 ;;
    --ssh-public-key) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_PUBLIC_KEY_FILE="$2"; shift 2 ;;
    --ssh-private-key) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_PRIVATE_KEY_FILE="$2"; shift 2 ;;
    --hf-token-env) [[ $# -ge 2 ]] || die "$1 requires a value"; HF_TOKEN_ENV="$2"; shift 2 ;;
    --hf-username-env) [[ $# -ge 2 ]] || die "$1 requires a value"; HF_USERNAME_ENV="$2"; shift 2 ;;
    --storage-account) [[ $# -ge 2 ]] || die "$1 requires a value"; STORAGE_ACCOUNT="$2"; shift 2 ;;
    --storage-account-env) [[ $# -ge 2 ]] || die "$1 requires a value"; STORAGE_ACCOUNT_ENV="$2"; shift 2 ;;
    --allow-existing-group) ALLOW_EXISTING_GROUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required"
[[ -n "$ORGANIZATION" ]] || die "--organization is required"
[[ -n "$PROJECT" ]] || die "--project is required"
[[ -n "$SERVICE_CONNECTION" ]] || die "--service-connection is required"
[[ -r "$SSH_PUBLIC_KEY_FILE" ]] || die "public key is not readable: $SSH_PUBLIC_KEY_FILE"
[[ -r "$SSH_PRIVATE_KEY_FILE" ]] || die "private key is not readable: $SSH_PRIVATE_KEY_FILE"
[[ -n "${!HF_TOKEN_ENV:-}" ]] || die "environment variable $HF_TOKEN_ENV is required"
[[ -n "${!HF_USERNAME_ENV:-}" ]] || die "environment variable $HF_USERNAME_ENV is required"

az devops configure --defaults organization="$ORGANIZATION" project="$PROJECT" >/dev/null

az devops service-endpoint list \
  --query "[?name=='${SERVICE_CONNECTION}'].name | [0]" \
  --output tsv | grep -Fxq "$SERVICE_CONNECTION" \
  || die "service connection not found: $SERVICE_CONNECTION"

GROUP_ID="$(az pipelines variable-group list \
  --query "[?name=='${GROUP_NAME}'].id | [0]" \
  --output tsv)"

if [[ -z "$GROUP_ID" ]]; then
  GROUP_ID="$(az pipelines variable-group create \
    --name "$GROUP_NAME" \
    --description "Secrets for the AI CPU benchmark pipeline" \
    --authorize true \
    --variables AZURE_SERVICE_CONNECTION="$SERVICE_CONNECTION" \
    --query id \
    --output tsv)"
  printf 'Created variable group %s (id %s).\n' "$GROUP_NAME" "$GROUP_ID"
else
  [[ "$ALLOW_EXISTING_GROUP" == true ]] || die "variable group already exists: $GROUP_NAME (use --allow-existing-group to update it)"
  printf 'Updating variable group %s (id %s).\n' "$GROUP_NAME" "$GROUP_ID"
  az pipelines variable-group variable update \
    --group-id "$GROUP_ID" \
    --name AZURE_SERVICE_CONNECTION \
    --value "$SERVICE_CONNECTION" \
    --output none
fi

set_variable() {
  local name="$1"
  local value="$2"
  az pipelines variable-group variable update \
    --group-id "$GROUP_ID" \
    --name "$name" \
    --value "$value" \
    --secret true \
    --output none 2>/dev/null || \
  az pipelines variable-group variable create \
    --group-id "$GROUP_ID" \
    --name "$name" \
    --value "$value" \
    --secret true \
    --output none
}

set_variable SSH_PUBLIC_KEY "$(<"$SSH_PUBLIC_KEY_FILE")"
set_variable SSH_PRIVATE_KEY "$(<"$SSH_PRIVATE_KEY_FILE")"
set_variable HF_TOKEN "${!HF_TOKEN_ENV}"
set_variable HF_USERNAME "${!HF_USERNAME_ENV}"

if [[ -n "$STORAGE_ACCOUNT" ]]; then
  set_variable STORAGE_ACCOUNT_NAME "$STORAGE_ACCOUNT"
elif [[ -n "${!STORAGE_ACCOUNT_ENV:-}" ]]; then
  set_variable STORAGE_ACCOUNT_NAME "${!STORAGE_ACCOUNT_ENV}"
fi

printf '\nVariable group configured: %s (id %s)\n' "$GROUP_NAME" "$GROUP_ID"
printf 'Configured variables: AZURE_SERVICE_CONNECTION, SSH_PUBLIC_KEY, SSH_PRIVATE_KEY, HF_TOKEN, HF_USERNAME\n'
[[ -n "$STORAGE_ACCOUNT" || -n "${!STORAGE_ACCOUNT_ENV:-}" ]] && printf 'Optional variable: STORAGE_ACCOUNT_NAME\n'
printf 'Secret values were not printed.\n'
