variable "subscription_id" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }
variable "tags" { type = map(string) default = {} }

variable "vnet_cidr" { type = string }
variable "aks_subnet_cidr" { type = string }
variable "private_endpoint_subnet_cidr" { type = string }
variable "postgres_subnet_cidr" { type = string }
variable "dns_service_ip" { type = string default = "10.250.0.10" }
variable "service_cidr" { type = string default = "10.250.0.0/16" }

variable "aks_vm_size" { type = string default = "Standard_D4ds_v5" }
variable "aks_system_min_count" { type = number default = 3 }
variable "aks_system_max_count" { type = number default = 5 }
variable "aks_user_min_count" { type = number default = 3 }
variable "aks_user_max_count" { type = number default = 10 }
variable "kubernetes_version" { type = string default = null }

variable "postgres_version" { type = string default = "16" }
variable "postgres_sku" { type = string default = "GP_Standard_D4s_v5" }
variable "postgres_storage_mb" { type = number default = 131072 }
variable "postgres_backup_retention_days" { type = number default = 7 }

variable "redis_sku" { type = string default = "Premium" }
variable "redis_capacity" { type = number default = 1 }

variable "acr_sku" { type = string default = "Premium" }
variable "storage_replication_type" { type = string default = "ZRS" }
variable "key_vault_purge_protection" { type = bool default = true }

variable "private_cluster" { type = bool default = true }
variable "enable_public_fqdn" { type = bool default = false }
variable "enable_azure_policy" { type = bool default = true }

variable "n8n_domain" { type = string default = "" }
variable "n8n_image_tag" { type = string }
variable "n8n_runner_image_tag" { type = string }
variable "n8n_chart_version" { type = string default = "1.10.1" }
