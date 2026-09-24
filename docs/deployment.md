# Deployment

1. Copy `environments/dev/.env.template` to `environments/dev/.env`.
2. Populate environment values and keep secrets in Key Vault.
3. Ensure `azure/networkpolicy-imds.yaml` is present and non-empty.
4. Run `./scripts/validate.sh dev`.
5. Run `./scripts/seed-keyvault.sh dev` when initializing Key Vault.
6. Run `./scripts/deploy.sh dev`.
7. Validate with `kubectl get pods -n n8n` and `./scripts/validate.sh dev`.

For production, create `environments/prod/` from the same templates and do not commit `.env` or certificates.
