#!/usr/bin/env bash
set -euo pipefail
ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"
KV="$(terraform output -raw key_vault_name)"
PGHOST="$(terraform output -raw postgres_host)"
REDIS="$(terraform output -raw redis_hostname)"
echo "Key Vault: $KV"
read -r -s -p "n8n Enterprise license key: " LICENSE; echo
read -r -s -p "Optional SMTP password (leave blank to skip): " SMTP; echo
ENC="$(openssl rand -base64 32)"
RUNNER="$(openssl rand -base64 32)"
APP="$(openssl rand -base64 24 | tr '/+' '_-')"
DBADMIN="$(terraform output -raw postgres_admin_username)"
DBPASS="$(terraform output -raw postgres_admin_password 2>/dev/null || true)"
# PostgreSQL admin password is sensitive and is intentionally not exposed by Terraform output.
# Obtain it once from `terraform output -raw postgres_admin_password` only if you add a protected
# sensitive output in your approved environment. Otherwise use the Azure portal/reset workflow.
az keyvault secret set --vault-name "$KV" --name n8n-encryption-key --value "$ENC" -o none
az keyvault secret set --vault-name "$KV" --name n8n-host --value "0.0.0.0" -o none
az keyvault secret set --vault-name "$KV" --name n8n-port --value "5678" -o none
az keyvault secret set --vault-name "$KV" --name n8n-protocol --value "https" -o none
az keyvault secret set --vault-name "$KV" --name n8n-db-password --value "$DBPASS" -o none
az keyvault secret set --vault-name "$KV" --name n8n-db-app-user --value "n8n_app" -o none
az keyvault secret set --vault-name "$KV" --name n8n-db-app-password --value "$APP" -o none
az keyvault secret set --vault-name "$KV" --name n8n-redis-password --value "$(az redis list-keys --name "$(terraform output -raw redis_hostname | cut -d. -f1)" --resource-group "$(terraform output -raw resource_group_name)" --query primaryKey -o tsv)" -o none
az keyvault secret set --vault-name "$KV" --name n8n-license-key --value "$LICENSE" -o none
az keyvault secret set --vault-name "$KV" --name n8n-runner-auth-token --value "$RUNNER" -o none
[ -n "$SMTP" ] && az keyvault secret set --vault-name "$KV" --name n8n-smtp-password --value "$SMTP" -o none
echo "Secrets seeded. Create the n8n_app database user using the PostgreSQL admin credentials approved by ADHA."
