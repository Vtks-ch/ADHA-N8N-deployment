# CLIENT MUST REVIEW ALL CIDRs, SKU/size, region, and version pins before apply.
subscription_id = "REPLACE_WITH_ADHA_DEV_SUBSCRIPTION_ID"
location = "REPLACE_WITH_AZURE_REGION"
environment = "dev"
name_prefix = "adha-n8n"
vnet_cidr = "10.50.0.0/16"
aks_subnet_cidr = "10.50.0.0/20"
private_endpoint_subnet_cidr = "10.50.16.0/24"
postgres_subnet_cidr = "10.50.17.0/24"
aks_vm_size = "Standard_D4ds_v5"
aks_system_min_count = 2
aks_system_max_count = 4
aks_user_min_count = 2
aks_user_max_count = 6
storage_replication_type = "ZRS"
acr_sku = "Premium"
n8n_image_tag = "2.27.3"
n8n_runner_image_tag = "2.27.3"
n8n_chart_version = "1.10.1"
tags = {
  Project = "ADHA"
  Workload = "n8n"
  Environment = "dev"
  Owner = "REPLACE"
  CostCenter = "REPLACE"
  DataClassification = "REPLACE"
}
