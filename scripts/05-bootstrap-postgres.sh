#!/usr/bin/env bash
set -euo pipefail
ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"
command -v psql >/dev/null || { echo "Install PostgreSQL client (psql) on a host with VNet/private DNS access."; exit 1; }
HOST="$(terraform output -raw postgres_host)"
ADMIN="$(terraform output -raw postgres_admin_username)"
ADMIN_PASSWORD="$(terraform output -raw postgres_admin_password)"
KV="$(terraform output -raw key_vault_name)"
APP_PASSWORD="$(az keyvault secret show --vault-name "$KV" --name n8n-db-app-password --query value -o tsv)"
export PGPASSWORD="$ADMIN_PASSWORD"
psql "host=$HOST port=5432 dbname=postgres user=$ADMIN sslmode=require" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'n8n_app') THEN
    CREATE ROLE n8n_app LOGIN PASSWORD '$APP_PASSWORD';
  ELSE
    ALTER ROLE n8n_app PASSWORD '$APP_PASSWORD';
  END IF;
END
\$\$;
GRANT CONNECT ON DATABASE n8n_enterprise TO n8n_app;
SQL
psql "host=$HOST port=5432 dbname=n8n_enterprise user=$ADMIN sslmode=require" <<'SQL'
GRANT USAGE, CREATE ON SCHEMA public TO n8n_app;
ALTER SCHEMA public OWNER TO n8n_app;
SQL
unset PGPASSWORD
echo "PostgreSQL n8n_app bootstrap completed."
