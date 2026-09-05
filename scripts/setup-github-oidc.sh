#!/usr/bin/env bash
# Create an Entra application, service principal, GitHub Actions federated
# credential, and Azure RBAC assignment for the benchmark workflow.
#
# This is a local prerequisite script. It does not create or store a client
# secret: GitHub Actions authenticates with the federated OIDC credential.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-github-oidc.sh --app-name NAME --owner OWNER --repo REPO [options]

Required:
  --app-name NAME       Entra application display name
  --owner OWNER         GitHub owner or organization
  --repo REPO           GitHub repository name

Options:
  --branch NAME         Trust this branch (default: main)
  --subject SUBJECT     Use an explicit GitHub OIDC subject instead of --branch
  --credential-name NAME
                        Federated credential name (default: github-actions)
  --role NAME            Azure role to assign (default: Contributor)
  --scope SCOPE          RBAC scope (default: /subscriptions/<current subscription>)
  --subscription-id ID  Select this Azure subscription before creating resources
  --tenant-id ID        Expected Entra tenant ID; fail if it does not match
  -h, --help            Show this help

Examples:
  setup-github-oidc.sh \
    --app-name ai-cpu-benchmark-github \
    --owner ThomVanL \
    --repo blog-2025-10-exploring-ai-cpu-inferencing-with-azure-cobalt-100

  setup-github-oidc.sh \
    --app-name ai-cpu-benchmark-prod \
    --owner ThomVanL \
    --repo blog-2025-10-exploring-ai-cpu-inferencing-with-azure-cobalt-100 \
    --subject repo:ThomVanL/blog-2025-10-exploring-ai-cpu-inferencing-with-azure-cobalt-100:environment:production \
    --scope /subscriptions/SUBSCRIPTION_ID/resourceGroups/rg-ai-benchmark
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

APP_NAME=""
OWNER=""
REPO=""
BRANCH="main"
SUBJECT=""
CREDENTIAL_NAME="github-actions"
ROLE="Contributor"
SCOPE=""
SUBSCRIPTION_ID=""
EXPECTED_TENANT_ID=""

while (($# > 0)); do
  case "$1" in
    --app-name)
      (($# >= 2)) || die "--app-name requires a value"
      APP_NAME="$2"
      shift 2
      ;;
    --owner)
      (($# >= 2)) || die "--owner requires a value"
      OWNER="$2"
      shift 2
      ;;
    --repo)
      (($# >= 2)) || die "--repo requires a value"
      REPO="$2"
      shift 2
      ;;
    --branch)
      (($# >= 2)) || die "--branch requires a value"
      BRANCH="$2"
      shift 2
      ;;
    --subject)
      (($# >= 2)) || die "--subject requires a value"
      SUBJECT="$2"
      shift 2
      ;;
    --credential-name)
      (($# >= 2)) || die "--credential-name requires a value"
      CREDENTIAL_NAME="$2"
      shift 2
      ;;
    --role)
      (($# >= 2)) || die "--role requires a value"
      ROLE="$2"
      shift 2
      ;;
    --scope)
      (($# >= 2)) || die "--scope requires a value"
      SCOPE="$2"
      shift 2
      ;;
    --subscription-id)
      (($# >= 2)) || die "--subscription-id requires a value"
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --tenant-id)
      (($# >= 2)) || die "--tenant-id requires a value"
      EXPECTED_TENANT_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -n "$APP_NAME" ]] || die "--app-name is required"
[[ -n "$OWNER" ]] || die "--owner is required"
[[ -n "$REPO" ]] || die "--repo is required"
[[ -z "$SUBJECT" || "$SUBJECT" != *$'\n'* ]] || die "--subject must be a single line"

if ! az account show --output none 2>/dev/null; then
  printf 'No Azure CLI session found; opening an interactive Azure login.\n' >&2
  az login --output none
fi

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

ACCOUNT_JSON="$(az account show --output json)"
CURRENT_SUBSCRIPTION_ID="$(jq -r '.id' <<<"$ACCOUNT_JSON")"
CURRENT_TENANT_ID="$(jq -r '.tenantId' <<<"$ACCOUNT_JSON")"

if [[ -n "$EXPECTED_TENANT_ID" && "$EXPECTED_TENANT_ID" != "$CURRENT_TENANT_ID" ]]; then
  die "current tenant '$CURRENT_TENANT_ID' does not match --tenant-id '$EXPECTED_TENANT_ID'"
fi

if [[ -z "$SCOPE" ]]; then
  SCOPE="/subscriptions/${CURRENT_SUBSCRIPTION_ID}"
fi

if [[ -z "$SUBJECT" ]]; then
  SUBJECT="repo:${OWNER}/${REPO}:ref:refs/heads/${BRANCH}"
fi

printf 'Creating Entra application: %s\n' "$APP_NAME"
CLIENT_ID="$(az ad app create \
  --display-name "$APP_NAME" \
  --query appId \
  --output tsv)"
[[ -n "$CLIENT_ID" ]] || die "Azure CLI did not return an application client ID"

if ! az ad sp show --id "$CLIENT_ID" --output none 2>/dev/null; then
  printf 'Creating service principal for %s\n' "$CLIENT_ID"
  az ad sp create --id "$CLIENT_ID" --output none
else
  printf 'Service principal already exists for %s\n' "$CLIENT_ID"
fi

if az ad app federated-credential list \
  --id "$CLIENT_ID" \
  --query "[?name=='${CREDENTIAL_NAME}'] | [0].name" \
  --output tsv | grep -Fxq "$CREDENTIAL_NAME"; then
  printf 'Federated credential already exists: %s\n' "$CREDENTIAL_NAME"
else
  FEDERATED_PARAMETERS="$(jq -n \
    --arg name "$CREDENTIAL_NAME" \
    --arg subject "$SUBJECT" \
    '{
      name: $name,
      issuer: "https://token.actions.githubusercontent.com",
      subject: $subject,
      audiences: ["api://AzureADTokenExchange"]
    }')"
  az ad app federated-credential create \
    --id "$CLIENT_ID" \
    --parameters "$FEDERATED_PARAMETERS" \
    --output none
fi

if az role assignment list \
  --assignee "$CLIENT_ID" \
  --scope "$SCOPE" \
  --role "$ROLE" \
  --query "[0].id" \
  --output tsv | grep -q .; then
  printf 'RBAC assignment already exists: %s at %s\n' "$ROLE" "$SCOPE"
else
  az role assignment create \
    --assignee "$CLIENT_ID" \
    --role "$ROLE" \
    --scope "$SCOPE" \
    --output none
fi

cat <<EOF

Configure these GitHub Actions values:
  AZURE_CLIENT_ID=$CLIENT_ID
  AZURE_TENANT_ID=$CURRENT_TENANT_ID
  AZURE_SUBSCRIPTION_ID=$CURRENT_SUBSCRIPTION_ID

Federated subject:
  $SUBJECT

RBAC:
  $ROLE
  $SCOPE

No client secret was created. The workflow must retain:
  permissions:
    id-token: write
    contents: read
EOF
