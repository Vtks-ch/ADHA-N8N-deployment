# Prerequisites

Azure resources that must already exist: Subscription, Resource Group, VNet/subnets, AKS, PostgreSQL Flexible Server, Azure Managed Redis, Storage Account, Key Vault, ACR, private DNS/private endpoints as required, DNS, and TLS certificate.

The deployment script automates the PostgreSQL database/user, Blob container, required RBAC, Kubernetes prerequisites, ingress/TLS configuration, and Helm deployment.
