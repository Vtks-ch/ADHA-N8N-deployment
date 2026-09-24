# ADHA n8n Enterprise on Azure AKS — Terraform + Helm Implementation Guide

## 1. Target architecture

Client network / VPN
        |
        | TCP 443
        v
Internal Azure Load Balancer
        |
        v
ingress-nginx (AKS)
        |
        +--> n8n Main (Enterprise Multi-Main)
        +--> n8n Webhook Processors
        +--> n8n Queue Workers
                 |
                 +--> Azure Redis (TLS 6380, Private Endpoint)
                 +--> Azure PostgreSQL Flexible Server (TLS 5432, delegated subnet)
                 +--> Azure Blob Storage (Private Endpoint, managed identity)
                 +--> Azure Key Vault (Private Endpoint, CSI + Workload Identity)
                 +--> Azure Container Registry (Private Endpoint)

This package deliberately uses an internal LoadBalancer for ingress-nginx. If ADHA requires
Azure Application Gateway/WAF in front of nginx, add that layer and change N8N_PROXY_HOPS
from 1 to 2 after the client-approved App Gateway configuration is implemented.

## 2. Environment model

Separate Terraform state is required for DEV, UAT and PROD.
Use one Azure subscription per environment if that is ADHA's governance model. If a shared
subscription is used, keep resource groups and state keys separate.

Suggested:
- DEV: environments/dev/terraform.tfvars
- UAT: environments/uat/terraform.tfvars
- PROD: environments/prod/terraform.tfvars

Do not copy DEV state into UAT/PROD.

## 3. Client prerequisites / information required

### Azure
- Tenant ID
- Subscription ID for each environment
- Approved Azure region
- Resource naming standard
- Mandatory tags: owner, cost center, project, data classification
- Azure Policy/Defender requirements
- Terraform execution identity (service principal or federated CI identity)
- Role: Contributor on target RG/subscription OR least-privilege custom role approved by ADHA

### Network
- ADHA VNet/IPAM approval for each environment
- VNet CIDR
- AKS subnet CIDR
- Private Endpoint subnet CIDR
- PostgreSQL delegated subnet CIDR
- Redis subnet CIDR
- Existing hub/spoke VNet and peering information
- Corporate DNS servers
- Private DNS forwarding design
- VPN/ExpressRoute connectivity
- NVA/Azure Firewall route requirements
- Allowed outbound FQDNs
- Approved ingress source CIDRs

### DNS/TLS
- n8n FQDN for each environment
- Internal or public DNS decision
- DNS A/CNAME record owner
- TLS certificate/full chain/private key
- Certificate renewal owner and process
- If App Gateway is used: listener hostname and certificate source

### n8n
- Enterprise license
- Exact approved n8n version
- Exact approved task-runner version
- Approved Helm chart version
- Concurrent user count
- Workflow execution rate
- Webhook rate
- Maximum payload size
- Required external APIs
- SSO method (SAML/OIDC)
- SMTP server, port, TLS mode and sender
- Custom CA certificates for internal APIs if needed
- Time zone

### Data services
- PostgreSQL HA/zone requirement
- Storage/backup retention
- RTO/RPO
- Redis tier and HA requirement
- Storage replication requirement
- DR region
- Data retention requirements

### Security
- Key Vault RBAC approval
- Private endpoints required for all PaaS services
- Defender for Cloud requirements
- Azure Policy assignments
- Container image scanning requirements
- Egress restrictions / firewall allow-list
- Kubernetes NetworkPolicy requirements
- Privileged access/PIM process
- Secret rotation requirements

## 4. Required ports

| Source | Destination | Port | Purpose |
|---|---|---:|---|
| ADHA users/VPN | Internal ingress LB | TCP 443 | n8n UI/API/webhooks |
| AKS | PostgreSQL | TCP 5432 | n8n database |
| AKS | Azure Redis | TCP 6380 | n8n queue |
| AKS | Key Vault | TCP 443 | CSI secret retrieval |
| AKS | ACR | TCP 443 | image pulls |
| AKS | Blob | TCP 443 | binary/execution storage |
| AKS | Azure control plane | TCP 443 | Azure API operations |
| DNS clients/nodes | Approved DNS | TCP/UDP 53 | name resolution |
| AKS | approved external APIs | TCP 443 | n8n integrations |

The exact external FQDN/IP allow-list must be supplied by ADHA security/network teams. Do not
create a broad `0.0.0.0/0` egress exception as a workaround.

## 5. Terraform workflow

### Step 0 — Workstation/jump host

Install:
- Azure CLI
- Terraform >= 1.8
- kubectl
- Helm 3
- OpenSSL
- PostgreSQL client (`psql`)
- Git
- Bash

The operator must have private network/DNS access to the AKS private endpoint and PostgreSQL
private endpoint for post-provisioning checks.

### Step 1 — Login

```bash
az login --tenant <ADHA_TENANT_ID>
az account set --subscription <ADHA_SUBSCRIPTION_ID>
az account show
```

For CI/CD, use a workload identity/federated service connection rather than a stored client secret.

### Step 2 — Edit the environment file

```bash
cp environments/dev/terraform.tfvars environments/dev/terraform.tfvars.local
```

Populate the approved values. Never put passwords, license keys or TLS private keys in tfvars.

### Step 3 — Remote Terraform state

Create an ADHA-controlled state storage account/container. Copy:

```text
terraform/backend.tf.example -> terraform/backend.tf
```

Use a different backend key for each environment, for example:
- `n8n/dev.tfstate`
- `n8n/uat.tfstate`
- `n8n/prod.tfstate`

Enable state locking and restrict state access.

### Step 4 — Provision

```bash
./scripts/01-provision-azure.sh dev
cd terraform
terraform apply dev.tfplan
```

Repeat for UAT/PROD only after the environment-specific inputs are approved.

### Step 5 — Configure AKS

```bash
./scripts/03-configure-aks.sh dev
kubectl get nodes
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

Record the internal ingress IP.

### Step 6 — Seed Key Vault

```bash
./scripts/04-seed-keyvault.sh dev
```

The script creates:
- n8n encryption key
- n8n host/port/protocol
- PostgreSQL admin password
- n8n application DB user/password
- Redis password
- Enterprise license
- task-runner authentication token

Do not email or commit generated secrets.

### Step 7 — Bootstrap PostgreSQL

Run from a machine that can resolve/reach the PostgreSQL private endpoint:

```bash
./scripts/05-bootstrap-postgres.sh dev
```

Validate:

```bash
psql "host=<postgres-fqdn> port=5432 dbname=n8n_enterprise user=n8n_app sslmode=require"
```

### Step 8 — DNS/TLS

Put the client-approved certificate files here temporarily:

```text
certs/fullchain.pem
certs/privkey.pem
```

Do not commit them.

Create the internal DNS A record:

```text
n8n-dev.<client-domain> -> <internal-ingress-ip>
```

For UAT/PROD use the approved FQDNs.

### Step 9 — Deploy n8n

Set the runtime domain:

```bash
export N8N_DOMAIN="n8n-dev.<client-domain>"
```

Then:

```bash
./scripts/deploy-adha.sh dev
```

Validate:

```bash
kubectl get pods -n n8n -o wide
kubectl get ingress -n n8n
kubectl get secret -n n8n
helm status n8n-enterprise -n n8n
```

### Step 10 — Application checks

```bash
kubectl rollout status deployment/n8n-enterprise-main -n n8n
kubectl get deploy -n n8n
kubectl get hpa -n n8n
kubectl get pdb -n n8n
kubectl get networkpolicy -n n8n
```

Then validate:
1. UI opens over HTTPS.
2. Login/SSO works.
3. Test workflow executes.
4. Queue worker processes execution.
5. Webhook reaches webhook processor.
6. Redis queue is healthy.
7. PostgreSQL connections are healthy.
8. Binary data can be written/read.
9. Task runner executes only approved modules.
10. Logs/metrics reach the ADHA observability platform.

## 6. Production hardening checklist

Before PROD:
- Use ADHA private DNS and firewall.
- Use a private AKS cluster.
- Use private endpoints for PaaS.
- Use Azure Policy.
- Use Defender/container image scanning.
- Use PIM for privileged access.
- Use workload identity for Key Vault.
- Keep n8n image and runner image pinned.
- Keep Helm chart pinned.
- Do not use `latest`/`stable`.
- Disable public access on PaaS.
- Store Terraform state remotely.
- Back up PostgreSQL.
- Test restore.
- Test n8n encryption-key recovery.
- Test certificate renewal.
- Test Redis failure/recovery.
- Test node failure and pod rescheduling.
- Test webhook recovery.
- Test DR runbook.

## 7. Rollback

Helm:

```bash
helm history n8n-enterprise -n n8n
helm rollback n8n-enterprise <REVISION> -n n8n
```

Terraform:

Do not blindly run `terraform destroy`. First identify the resource that changed:

```bash
terraform plan -var-file=environments/prod/terraform.tfvars
```

Application rollback and infrastructure rollback are separate operations.

## 8. Important implementation notes

- The package's supplied n8n chart is retained under `helm/n8n-hosting-acr/charts/n8n`.
- The new Terraform layer creates the Azure infrastructure rather than assuming that AKS/PaaS
  resources already exist.
- The new deployment path uses an internal ingress LoadBalancer.
- Key Vault CSI access uses a dedicated user-assigned identity with AKS Workload Identity.
- Azure Blob access uses the AKS kubelet identity with Storage Blob Data Contributor. ADHA can
  replace this with a dedicated workload identity if required.
- PostgreSQL is private and uses SSL.
- Redis is private and TLS-only.
- ACR is private and runtime images are imported into it.
- The client must approve n8n/runner/chart versions before production.

## 9. Do not do these in production

- Do not store secrets in Git.
- Do not commit `.tfstate`.
- Do not commit `.env`.
- Do not expose PostgreSQL/Redis/Key Vault publicly just to make deployment work.
- Do not use wildcard internet egress when a defined allow-list is required.
- Do not delete the n8n namespace as part of a routine upgrade.
- Do not change the n8n encryption key after data has been created.
