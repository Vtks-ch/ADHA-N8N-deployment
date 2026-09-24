# CLIENT MUST REVIEW ALL CIDRs, SKU/size, region, and version pins before apply.
subscription_id = "REPLACE_WITH_ADHA_UAT_SUBSCRIPTION_ID"
location = "REPLACE_WITH_AZURE_REGION"
environment = "uat"
name_prefix = "adha-n8n"
vnet_cidr = "10.60.0.0/16"
aks_subnet_cidr = "10.60.0.0/20"
private_endpoint_subnet_cidr = "10.60.16.0/24"
postgres_subnet_cidr = "10.60.17.0/24"
aks_vm_size = "Standard_D4ds_v5"
aks_system_min_count = 3
aks_system_max_count = 6
aks_user_min_count = 3
aks_user_max_count = 8
storage_replication_type = "ZRS"
acr_sku = "Standard"
n8n_image_tag = "2.27.3"
n8n_runner_image_tag = "2.27.3"
n8n_chart_version = "1.10.1"
tags = {
  Project = "ADHA"
  Workload = "n8n"
  Environment = "uat"
  Owner = "REPLACE"
  CostCenter = "REPLACE"
  DataClassification = "REPLACE"
}
