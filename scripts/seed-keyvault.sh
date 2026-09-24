#!/bin/bash
# =============================================================================
# Seed Azure KeyVault with n8n secrets
# =============================================================================
# Run ONCE to populate KeyVault. After this, CSI driver handles sync to K8s.
# =============================================================================

set -euo pipefail

# Auto-load .env so POSTGRES_APP_USER / KEYVAULT_NAME are available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${1:-dev}}"
ENV_DIR="$PROJECT_DIR/environments/$ENVIRONMENT_NAME"
ENV_FILE="$ENV_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
  set +a
fi

if [ -z "${AZURE_KEYVAULT_NAME:-}" ]; then
  echo "[ERROR] AZURE_KEYVAULT_NAME not set in .env. Cannot proceed." >&2
  exit 1
fi
KEYVAULT_NAME="$AZURE_KEYVAULT_NAME"

echo "=== Seeding n8n secrets into Azure KeyVault: $KEYVAULT_NAME ==="

# 1. Encryption Key (auto-generate if first time)
ENCRYPTION_KEY=$(openssl rand -base64 32)
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-encryption-key" --value "$ENCRYPTION_KEY" -o none
echo "[CRITICAL] Encryption key written to the backup file — move it to secure storage, then delete the file."
echo "$ENCRYPTION_KEY" > "$ENV_DIR/n8n-encryption-key.backup.txt"
chmod 600 "$ENV_DIR/n8n-encryption-key.backup.txt"

# 1b. n8n core config (host/port/protocol) — REQUIRED by chart's
# _environment-helpers.tpl which hard-codes secretKeyRef for these keys.
# Even though they aren't truly secret, the chart enforces this pattern.
# Source: https://raw.githubusercontent.com/n8n-io/n8n-hosting/main/charts/n8n/templates/_environment-helpers.tpl
PROTOCOL_VALUE="${N8N_PROTOCOL:-http}"
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-host" --value "0.0.0.0" -o none
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-port" --value "5678" -o none
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-protocol" --value "$PROTOCOL_VALUE" -o none
echo "[INFO] n8n-protocol set to: $PROTOCOL_VALUE"

# 2. Database — admin password (used ONLY for bootstrap, not at runtime)
read -sp "Enter PostgreSQL ADMIN password (server admin, used for bootstrap): " DB_PASSWORD
echo
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-db-password" --value "$DB_PASSWORD" -o none

# 2b. Database — non-root app user (n8n connects as THIS user at runtime)
# Mirrors the POSTGRES_NON_ROOT_USER pattern from official n8n manifests.
# Run scripts/db-bootstrap.sql against your Postgres ONCE to create this user.
APP_USER="${POSTGRES_APP_USER:-n8n_app}"
APP_PASSWORD=$(openssl rand -base64 24)
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-db-app-user" --value "$APP_USER" -o none
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-db-app-password" --value "$APP_PASSWORD" -o none
echo "[INFO] Generated non-root app user: $APP_USER"
echo "[INFO] Generated app user password (saved to backup file)"
echo "$APP_PASSWORD" > "$ENV_DIR/n8n-db-app-password.backup.txt"
chmod 600 "$ENV_DIR/n8n-db-app-password.backup.txt"
echo "[ACTION REQUIRED] Run scripts/db-bootstrap.sql on your Postgres to create the user."

# 3. Redis password
read -sp "Enter Redis password (Azure Redis access key): " REDIS_PASSWORD
echo
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-redis-password" --value "$REDIS_PASSWORD" -o none

# 4. License key
read -sp "Enter n8n Enterprise License key: " LICENSE_KEY
echo
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-license-key" --value "$LICENSE_KEY" -o none

# 5. S3 credentials — REMOVED (S3 deprecated; Azure Blob external storage uses
#    managed identity, no KV secret needed). See .env "External data storage".

# 6. Task Runner auth token (auto-generate)
RUNNER_TOKEN=$(openssl rand -base64 32)
az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-runner-auth-token" --value "$RUNNER_TOKEN" -o none

# 7. SMTP password (OPTIONAL — for user invites, password resets, error emails)
read -p "Configure SMTP now? (y/N): " CONFIGURE_SMTP
if [[ "$CONFIGURE_SMTP" =~ ^[Yy]$ ]]; then
  read -sp "Enter SMTP password: " SMTP_PASSWORD
  echo
  az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "n8n-smtp-password" --value "$SMTP_PASSWORD" -o none
  echo "[INFO] SMTP password stored. Next steps:"
  echo "  1. Uncomment SMTP entries in azure/secret-provider-class.yaml"
  echo "  2. Uncomment SMTP env vars in values-enterprise.yaml (config.extraEnv)"
  echo "  3. Re-run ./scripts/deploy.sh"
else
  echo "[SKIP] SMTP not configured. To add later:"
  echo "  az keyvault secret set --vault-name $KEYVAULT_NAME --name n8n-smtp-password --value '<pass>' -o none"
fi

echo ""
echo "=== All secrets seeded successfully ==="
echo "KeyVault: $KEYVAULT_NAME"
echo "Secrets created:"
echo "  - n8n-encryption-key"
echo "  - n8n-db-password         (admin — bootstrap only)"
echo "  - n8n-db-app-user         (non-root app user — used by n8n)"
echo "  - n8n-db-app-password     (non-root app user password)"
echo "  - n8n-redis-password"
echo "  - n8n-license-key"
echo "  - n8n-runner-auth-token"
if [[ "$CONFIGURE_SMTP" =~ ^[Yy]$ ]]; then
  echo "  - n8n-smtp-password       (SMTP — optional)"
fi
