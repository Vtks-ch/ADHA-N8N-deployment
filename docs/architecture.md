# Architecture

AKS hosts n8n main, queue workers, webhook processors, and external task runners. PostgreSQL is the external database, Redis is the queue backend, Azure Blob is object/binary storage, Key Vault is the secret store, and ACR supplies the image/chart artifacts.

Production baseline from the supplied configuration: 3 main pods, 4 queue workers, 3 webhook processors, HPA enabled, PDB enabled, NetworkPolicy enabled.
