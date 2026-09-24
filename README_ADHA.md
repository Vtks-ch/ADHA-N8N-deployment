# ADHA n8n Enterprise — Azure AKS Terraform Deployment Package

This package combines the supplied n8n Enterprise Helm implementation with a new Terraform
layer that provisions the Azure infrastructure required by ADHA DEV/UAT/PROD.

## Start here

1. Read `docs/ADHA_IMPLEMENTATION_GUIDE.md`.
2. Complete `docs/CLIENT_INPUT_MATRIX.csv`.
3. Complete `docs/FIREWALL_ACCESS_MATRIX.csv`.
4. Review each environment's `terraform.tfvars`.
5. Configure the ADHA Terraform backend.
6. Run `scripts/01-provision-azure.sh <env>`.
7. Apply the approved plan.
8. Run `scripts/03-configure-aks.sh <env>`.
9. Seed Key Vault.
10. Bootstrap PostgreSQL.
11. Configure DNS/TLS.
12. Run `scripts/deploy-adha.sh <env>`.
13. Perform the acceptance tests.

## Important

The Terraform files are a production-oriented baseline, not a substitute for ADHA's approved
IPAM, security, DNS, firewall, backup, DR, naming and governance standards.

Never commit:
- `.tfstate`
- `.tfplan`
- `.env`
- TLS private keys
- license keys
- Key Vault secret values
- generated rendered Helm values containing sensitive information
