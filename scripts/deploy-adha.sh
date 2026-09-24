#!/usr/bin/env bash
set -euo pipefail
ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/terraform"
ENV="$ROOT/environments/$ENVIRONMENT"
NAMESPACE=n8n
cd "$TF"
RG="$(terraform output -raw resource_group_name)"
AKS="$(terraform output -raw aks_name)"
ACR="$(terraform output -raw acr_name)"
KV="$(terraform output -raw key_vault_name)"
PGHOST="$(terraform output -raw postgres_host)"
REDISHOST="$(terraform output -raw redis_hostname)"
STORAGE="$(terraform output -raw storage_account_name)"
KV_ID="$(terraform output -raw n8n_kv_identity_client_id)"
KUBELET_ID="$(terraform output -raw kubelet_identity_client_id)"
IMAGE_TAG="$(grep '^n8n_image_tag' "$ENV/terraform.tfvars" | cut -d'"' -f2)"
RUNNER_TAG="$(grep '^n8n_runner_image_tag' "$ENV/terraform.tfvars" | cut -d'"' -f2)"
DOMAIN="${N8N_DOMAIN:-}"
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
sed "s|<N8N_KV_IDENTITY_CLIENT_ID>|$KV_ID|g" "$ROOT/azure/serviceaccount.yaml" | kubectl apply -f -
sed -e "s|<N8N_KV_IDENTITY_CLIENT_ID>|$KV_ID|g" \
    -e "s|<AZURE_KEYVAULT_NAME>|$KV|g" \
    -e "s|<AZURE_TENANT_ID>|$(az account show --query tenantId -o tsv)|g" \
    "$ROOT/azure/secret-provider-class.yaml" | kubectl apply -f -
kubectl apply -f "$ROOT/azure/secret-provider-pod.yaml"
# Import pinned images into private ACR; this avoids direct runtime pulls from Docker Hub.
az acr import --name "$ACR" --source "docker.io/n8nio/n8n:$IMAGE_TAG" --image "n8nio/n8n:$IMAGE_TAG" --force
az acr import --name "$ACR" --source "docker.io/n8nio/runners:$RUNNER_TAG" --image "n8nio/runners:$RUNNER_TAG" --force
# Wait for CSI synced Kubernetes Secrets.
kubectl rollout status deployment/n8n-secret-sync -n "$NAMESPACE" --timeout=180s
kubectl wait --for=jsonpath='{.data.N8N_ENCRYPTION_KEY}' secret/n8n-core-secrets -n "$NAMESPACE" --timeout=180s
# TLS: client supplies PEM certificate/key under certs/.
if [ -n "$DOMAIN" ]; then
  test -f "$ROOT/certs/fullchain.pem" && test -f "$ROOT/certs/privkey.pem" || {
    echo "N8N_DOMAIN is set. Put client-approved TLS files at certs/fullchain.pem and certs/privkey.pem."; exit 1; }
  kubectl create secret tls n8n-tls -n "$NAMESPACE" --cert="$ROOT/certs/fullchain.pem" --key="$ROOT/certs/privkey.pem" --dry-run=client -o yaml | kubectl apply -f -
fi
# Render the supplied enterprise values file without changing the source template.
TMP="$(mktemp)"
cp "$ENV/values-enterprise.yaml" "$TMP"
sed -i \
  -e "s|<N8N_IMAGE_TAG>|$IMAGE_TAG|g" \
  -e "s|<RUNNERS_IMAGE_TAG>|$RUNNER_TAG|g" \
  -e "s|<AZURE_POSTGRES_HOST>|$PGHOST|g" \
  -e "s|<POSTGRES_DB_NAME>|n8n_enterprise|g" \
  -e "s|<POSTGRES_APP_USER>|n8n_app|g" \
  -e "s|<AZURE_REDIS_HOST>|$REDISHOST|g" \
  -e "s|<AZURE_REDIS_PORT>|6380|g" \
  -e "s|<N8N_DOMAIN>|${DOMAIN:-placeholder.invalid}|g" \
  -e "s|<N8N_TLS_SECRET_NAME>|n8n-tls|g" \
  -e "s|<N8N_PROTOCOL>|${N8N_PROTOCOL:-https}|g" \
  -e "s|<AZURE_STORAGE_ACCOUNT>|$STORAGE|g" \
  -e "s|<AZURE_STORAGE_CONTAINER>|n8n-data|g" \
  -e "s|<BINARY_DATA_MODE>|azure|g" \
  -e "s|<EXECUTION_DATA_STORAGE_MODE>|azure|g" \
  -e "s|<POD_IDENTITY_CLIENT_ID>|$KUBELET_ID|g" \
  "$TMP"
sed -i '/name: N8N_PROXY_HOPS/{n;s/value: "2"/value: "1"/;}' "$TMP"
# Force private ACR images and service account.
helm upgrade --install n8n-enterprise "$ROOT/helm/n8n-hosting-acr/charts/n8n" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$TMP" \
  --set image.repository="$ACR.azurecr.io/n8nio/n8n" \
  --set image.tag="$IMAGE_TAG" \
  --set taskRunners.image.repository="$ACR.azurecr.io/n8nio/runners" \
  --set taskRunners.image.tag="$RUNNER_TAG" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=n8n-enterprise \
  --set ingress.enabled="$([ -n "$DOMAIN" ] && echo true || echo false)" \
  --set ingress.webhookProcessor.enabled="$([ -n "$DOMAIN" ] && echo true || echo false)" \
  --wait --timeout 15m
rm -f "$TMP"
kubectl get pods -n "$NAMESPACE" -o wide
kubectl get ingress -n "$NAMESPACE" || true
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide
echo "n8n deployment completed. Configure client DNS to the internal ingress IP shown above."
