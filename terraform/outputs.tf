output "resource_group_name" { value = azurerm_resource_group.this.name }
output "aks_name" { value = azurerm_kubernetes_cluster.this.name }
output "acr_name" { value = azurerm_container_registry.this.name }
output "acr_login_server" { value = azurerm_container_registry.this.login_server }
output "key_vault_name" { value = azurerm_key_vault.this.name }
output "postgres_host" { value = azurerm_postgresql_flexible_server.this.fqdn }
output "postgres_admin_username" { value = azurerm_postgresql_flexible_server.this.administrator_login }
output "redis_hostname" { value = azurerm_redis_cache.this.hostname }
output "redis_port" { value = 6380 }
output "storage_account_name" { value = azurerm_storage_account.this.name }
output "aks_oidc_issuer_url" { value = azurerm_kubernetes_cluster.this.oidc_issuer_url }
output "kubelet_identity_client_id" { value = azurerm_kubernetes_cluster.this.kubelet_identity[0].client_id }

output "n8n_kv_identity_client_id" { value = azurerm_user_assigned_identity.n8n_kv.client_id }
output "postgres_admin_password" { value = azurerm_postgresql_flexible_server.this.administrator_password sensitive = true }
output "kubelet_identity_client_id" { value = azurerm_kubernetes_cluster.this.kubelet_identity[0].client_id }
