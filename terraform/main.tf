locals {
  rg_name        = "rg-${var.name_prefix}-${var.environment}"
  vnet_name      = "vnet-${var.name_prefix}-${var.environment}"
  aks_name       = "aks-${var.name_prefix}-${var.environment}"
  acr_name       = lower(replace("acr${var.name_prefix}${var.environment}", "-", ""))
  kv_name        = lower(substr(replace("kv-${var.name_prefix}-${var.environment}", "-", ""), 0, 24))
  storage_name   = lower(substr(replace("st${var.name_prefix}${var.environment}n8ndata", "-", ""), 0, 24))
  pg_name        = lower(replace("psql-${var.name_prefix}-${var.environment}", "-", ""))
  redis_name     = lower(replace("redis-${var.name_prefix}-${var.environment}", "-", ""))
  tags = merge(var.tags, {
    Environment = var.environment
    Application = "n8n"
    ManagedBy   = "Terraform"
  })
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = local.vnet_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_endpoint_subnet_cidr]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.postgres_subnet_cidr]
  delegation {
    name = "fs"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.pg_name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  resource_group_name   = azurerm_resource_group.this.name
}

resource "random_password" "postgres_admin" {
  length = 32
  special = true
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                   = local.pg_name
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  version                = var.postgres_version
  delegated_subnet_id    = azurerm_subnet.postgres.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres.id
  administrator_login    = "n8nadmin"
  administrator_password = random_password.postgres_admin.result
  storage_mb             = var.postgres_storage_mb
  sku_name               = var.postgres_sku
  backup_retention_days  = var.postgres_backup_retention_days
  public_network_access_enabled = false
  zone = "1"
  tags = local.tags
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "n8n" {
  name      = "n8n_enterprise"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_redis_cache" "this" {
  name                = local.redis_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  capacity            = var.redis_capacity
  family              = var.redis_sku == "Premium" ? "P" : "C"
  sku_name            = var.redis_sku
  minimum_tls_version = "1.2"
  non_ssl_port_enabled = false
  public_network_access_enabled = false
  redis_version = "6"
  tags = local.tags
}

resource "azurerm_storage_account" "this" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = var.storage_replication_type
  min_tls_version          = "TLS1_2"
  public_network_access_enabled = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled = false
  tags = local.tags
}
resource "azurerm_storage_container" "n8n" {
  name                  = "n8n-data"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.acr_sku
  admin_enabled       = false
  public_network_access_enabled = false
  tags = local.tags
}

resource "azurerm_key_vault" "this" {
  name                          = local.kv_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = var.key_vault_purge_protection
  soft_delete_retention_days    = 90
  public_network_access_enabled = false
  enable_rbac_authorization     = true
  tags = local.tags
}

data "azurerm_client_config" "current" {}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.aks_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = "${var.name_prefix}-${var.environment}"
  kubernetes_version  = var.kubernetes_version
  private_cluster_enabled = var.private_cluster
  private_cluster_public_fqdn_enabled = var.enable_public_fqdn
  oidc_issuer_enabled = true
  workload_identity_enabled = true
  azure_policy_enabled = var.enable_azure_policy
  role_based_access_control_enabled = true
  sku_tier = var.environment == "prod" ? "Standard" : "Free"

  default_node_pool {
    name                 = "system"
    vm_size              = var.aks_vm_size
    vnet_subnet_id       = azurerm_subnet.aks.id
    type                 = "VirtualMachineScaleSets"
    auto_scaling_enabled = true
    min_count            = var.aks_system_min_count
    max_count            = var.aks_system_max_count
    os_sku               = "AzureLinux"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_plugin_mode = "overlay"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
  }

  storage_profile {
    blob_driver_enabled = true
    disk_driver_enabled = true
    file_driver_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
    secret_rotation_interval = "2m"
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "n8n"
  kubernetes_cluster_id  = azurerm_kubernetes_cluster.this.id
  vm_size               = var.aks_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  auto_scaling_enabled   = true
  min_count              = var.aks_user_min_count
  max_count              = var.aks_user_max_count
  mode                  = "User"
  os_type               = "Linux"
  os_sku                = "AzureLinux"
  node_labels = { "workload" = "n8n" }
  tags = local.tags
}


resource "azurerm_user_assigned_identity" "n8n_kv" {
  name                = "id-${var.name_prefix}-${var.environment}-kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}

resource "azurerm_role_assignment" "n8n_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.n8n_kv.principal_id
}

resource "azurerm_federated_identity_credential" "n8n_kv" {
  name                = "fic-n8n-kv"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.n8n_kv.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:n8n:n8n-enterprise"
  depends_on          = [azurerm_kubernetes_cluster.this]
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "storage_blob" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name = "redis-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id = azurerm_virtual_network.this.id
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_endpoint" "redis" {
  name = "pe-${local.redis_name}"
  location = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name = "redis-connection"
    private_connection_resource_id = azurerm_redis_cache.this.id
    is_manual_connection = false
    subresource_names = ["redisCache"]
  }
  private_dns_zone_group {
    name = "redis-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
  tags = local.tags
}

resource "azurerm_private_dns_zone" "acr" {
  name = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name = "acr-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id = azurerm_virtual_network.this.id
  resource_group_name = azurerm_resource_group.this.name
}
resource "azurerm_private_endpoint" "acr" {
  name = "pe-${local.acr_name}"
  location = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name = "acr-connection"
    private_connection_resource_id = azurerm_container_registry.this.id
    is_manual_connection = false
    subresource_names = ["registry"]
  }
  private_dns_zone_group {
    name = "acr-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
  tags = local.tags
}


resource "azurerm_private_dns_zone" "acr_data" {
  name                = "privatelink.${var.location}.data.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "acr_data" {
  name                  = "acr-data-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.acr_data.name
  virtual_network_id    = azurerm_virtual_network.this.id
  resource_group_name   = azurerm_resource_group.this.name
}
resource "azurerm_private_endpoint" "acr_data" {
  name                = "pe-${local.acr_name}-data"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "acr-data-connection"
    private_connection_resource_id = azurerm_container_registry.this.id
    is_manual_connection           = false
    subresource_names              = ["data"]
  }
  private_dns_zone_group {
    name                 = "acr-data-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr_data.id]
  }
  tags = local.tags
}

resource "azurerm_private_dns_zone" "kv" {
  name = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  name = "kv-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id = azurerm_virtual_network.this.id
  resource_group_name = azurerm_resource_group.this.name
}
resource "azurerm_private_endpoint" "kv" {
  name = "pe-${local.kv_name}"
  location = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name = "kv-connection"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection = false
    subresource_names = ["vault"]
  }
  private_dns_zone_group {
    name = "kv-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
  tags = local.tags
}

resource "azurerm_private_dns_zone" "storage" {
  name = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  name = "storage-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.storage.name
  virtual_network_id = azurerm_virtual_network.this.id
  resource_group_name = azurerm_resource_group.this.name
}
resource "azurerm_private_endpoint" "storage" {
  name = "pe-${local.storage_name}"
  location = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name = "storage-connection"
    private_connection_resource_id = azurerm_storage_account.this.id
    is_manual_connection = false
    subresource_names = ["blob"]
  }
  private_dns_zone_group {
    name = "storage-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage.id]
  }
  tags = local.tags
}
