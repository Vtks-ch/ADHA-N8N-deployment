#!/usr/bin/env bash
set -euo pipefail
ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"
RG="$(terraform output -raw resource_group_name)"
AKS="$(terraform output -raw aks_name)"
ACR="$(terraform output -raw acr_name)"
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
kubectl get nodes -o wide
az aks update -g "$RG" -n "$AKS" --attach-acr "$ACR" >/dev/null || true
kubectl create namespace n8n --dry-run=client -o yaml | kubectl apply -f -
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true"
echo "AKS configured. Get ingress IP with:"
echo "kubectl get svc -n ingress-nginx ingress-nginx-controller"
