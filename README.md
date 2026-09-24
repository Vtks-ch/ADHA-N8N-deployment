# n8n Enterprise Platform

Deployment source for n8n Enterprise on Azure AKS. The repository separates environment configuration from Kubernetes/Azure deployment logic.

## Repository

- `environments/<env>/.env.template` — environment template; copy to `.env` locally.
- `environments/<env>/values-enterprise.yaml` — Helm values template.
- `azure/` — Key Vault CSI, IMDS NetworkPolicy, CA and task-runner configuration.
- `scripts/deploy.sh` — main deployment automation.
- `scripts/validate.sh` — validation.
- `scripts/seed-keyvault.sh` — Key Vault initialization.

## Deployment

```bash
cp environments/dev/.env.template environments/dev/.env
# edit environments/dev/.env
chmod +x scripts/*.sh
./scripts/validate.sh dev
./scripts/seed-keyvault.sh dev
./scripts/deploy.sh dev
```

The scripts use the environment name as the first argument. If omitted, `dev` is used.

## Azure prerequisites

Subscription, Resource Group, VNet/subnets, AKS, PostgreSQL Flexible Server, Redis, Storage Account, Key Vault, ACR, private networking/DNS where required, DNS and TLS must be prepared before deployment.

## Automated actions

`deploy.sh` checks the Azure/AKS context, Key Vault CSI provider, ACR artifacts, Key Vault access, Storage Blob RBAC/container, Kubernetes namespace/service account/SecretProviderClass, IMDS NetworkPolicy, ingress/TLS, CA/task-runner configuration, PostgreSQL database/application user, and Helm release.

## Security

Never commit `.env`, PFX/private keys, encryption-key backups, passwords, license keys, or rendered secret files.

## Critical IMDS requirement

`azure/networkpolicy-imds.yaml` must exist and allow TCP/80 to `169.254.169.254/32` for the n8n pods selected by the policy. This fixes the mismatch found in the supplied production package where `networkpolicy-imds_prod.yaml` was empty while `deploy.sh` expected `networkpolicy-imds.yaml`.
