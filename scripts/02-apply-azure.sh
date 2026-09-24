#!/usr/bin/env bash
set -euo pipefail
ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"
test -f "$ENVIRONMENT.tfplan" || { echo "Run 01-provision-azure.sh first"; exit 1; }
terraform apply "$ENVIRONMENT.tfplan"
terraform output > "$ROOT/environments/$ENVIRONMENT/terraform-outputs.txt"
