#!/usr/bin/env bash
set -euo pipefail
ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/terraform"
TFVARS="$ROOT/environments/$ENVIRONMENT/terraform.tfvars"
test -f "$TFVARS" || { echo "Missing $TFVARS"; exit 1; }
command -v az >/dev/null || { echo "Azure CLI required"; exit 1; }
command -v terraform >/dev/null || { echo "Terraform required"; exit 1; }
az account show >/dev/null || az login
cd "$TF"
terraform init
terraform fmt -check
terraform validate
terraform plan -var-file="$TFVARS" -out="$ENVIRONMENT.tfplan"
echo "Review plan, then run:"
echo "terraform apply $ENVIRONMENT.tfplan"
