# ADHA Client Handover / Acceptance Checklist

## Infrastructure
- [ ] Subscription/tenant verified
- [ ] Resource group naming approved
- [ ] VNet/subnets approved by IPAM
- [ ] AKS private cluster reachable from ADHA admin network
- [ ] AKS nodes Ready
- [ ] ACR private endpoint resolves
- [ ] Key Vault private endpoint resolves
- [ ] PostgreSQL private endpoint resolves
- [ ] Redis private endpoint resolves
- [ ] Storage private endpoint resolves

## Network
- [ ] TCP 443 user -> ingress approved
- [ ] TCP 5432 AKS -> PostgreSQL approved
- [ ] TCP 6380 AKS -> Redis approved
- [ ] TCP 443 AKS -> ACR/KV/Blob approved
- [ ] DNS forwarding works
- [ ] Required external API egress allow-list implemented

## n8n
- [ ] Enterprise license loaded
- [ ] n8n version approved
- [ ] Runner version approved
- [ ] Helm chart version approved
- [ ] Multi-main healthy
- [ ] Workers healthy
- [ ] Webhook processors healthy
- [ ] Task runners healthy
- [ ] HPA healthy
- [ ] PDB healthy
- [ ] NetworkPolicy present

## Security
- [ ] TLS valid and trusted
- [ ] Key Vault RBAC verified
- [ ] Workload Identity verified
- [ ] No secrets in repository
- [ ] ACR admin disabled
- [ ] Public access disabled for PaaS resources
- [ ] PIM used for privileged operations
- [ ] Defender/Policy checks passed

## Application
- [ ] n8n UI login works
- [ ] SSO works
- [ ] Test workflow succeeds
- [ ] Queue execution succeeds
- [ ] Production webhook succeeds
- [ ] Binary data upload/download succeeds
- [ ] SMTP test succeeds if enabled
- [ ] External API integration succeeds
- [ ] Logs/metrics visible
- [ ] Backup/restore test completed

## Operations
- [ ] Monitoring alerts configured
- [ ] Incident contacts recorded
- [ ] Certificate renewal owner recorded
- [ ] Secret rotation process recorded
- [ ] DR runbook tested
- [ ] Rollback tested
- [ ] Terraform state access restricted
