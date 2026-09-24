# Troubleshooting

## Azure Blob connectivity
Check NetworkPolicy, Azure identity, Storage Blob Data Contributor, DNS/private networking, and IMDS access.

## Key Vault CSI failure
Check the AKS Key Vault Secrets Provider add-on, identity/RBAC, SecretProviderClass, Key Vault network access, and pod events.

## Webhook 404
Check webhook processor Deployment/Service/Ingress and confirm production webhooks are disabled on main as intended.

## Database/Redis failure
Check private DNS, firewall/NSG rules, TLS, host/port, and credentials.
