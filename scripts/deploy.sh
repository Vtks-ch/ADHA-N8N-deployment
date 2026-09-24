#!/bin/bash
# =============================================================================
# n8n Enterprise on AKS - SINGLE MASTER SCRIPT
# =============================================================================
# Type ONE command:  ./scripts/deploy.sh
#
# What this does:
#    1. Pre-flight (tools, Azure login, kubectl)
#    2. Auto-detect AKS kubelet identity (no Workload Identity needed)
#    3. ACR image import (if ACR_NAME set — imports from Docker Hub to ACR)
#    4. Verify KeyVault secrets exist (created by admin)
#    5. Grant kubelet identity 'Key Vault Secrets User' on KV
#   5b. Grant Blob 'Storage Blob Data Contributor' + create container (if Azure Blob storage set)
#    6. Cleanup any old n8n state (clean slate)
#    7. Render config templates from .env (originals never modified)
#    8. Create namespace + ServiceAccount + SecretProviderClass + sync pod
#    9. Install nginx-ingress + create TLS secret (if N8N_DOMAIN set)
#   10. Bootstrap PostgreSQL (create DB + app user via az CLI)
#   11. Obtain the Helm chart — from the private ACR if ACR_NAME is set (imported
#   12. Helm install n8n using the local chart (bypasses ghcr.io blob CDN)
#   13. Validate + print access URL (ingress domain, or port-forward instructions)
#
# Standards followed (per official chart at github.com/n8n-io/n8n-hosting):
#   - Helm chart v1.10.1, app version 2.29.9
#   - Multi-Main HA, Queue mode, Workers, Webhook processors, Task Runners
#   - External Postgres (Azure), External Redis (Azure)
#   - External binary/execution storage: Azure Blob (managed identity) or database mode
#   - Non-root Postgres app user (POSTGRES_NON_ROOT_USER pattern)
#   - K8s Secrets for sensitive data (no plain-text env vars)
#   - HPA + PDB + RBAC + ClusterIP + ingress-nginx (no LoadBalancer for n8n itself)
#
# Idempotent: safe to re-run. Stops cleanly on any error.
# =============================================================================

set -uo pipefail

# === Configuration ======================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${1:-dev}}"
ENV_DIR="$PROJECT_DIR/environments/$ENVIRONMENT_NAME"
ENV_FILE="$ENV_DIR/.env"
NAMESPACE="n8n"
RELEASE_NAME="n8n-enterprise"
VALUES_TEMPLATE="$ENV_DIR/values-enterprise.yaml"
VALUES_FILE="$ENV_DIR/values-enterprise-rendered.yaml"
SPC_TEMPLATE="$PROJECT_DIR/azure/secret-provider-class.yaml"
SPC_FILE="$PROJECT_DIR/azure/secret-provider-class-rendered.yaml"

# Chart resolution
# ============================================================================
# PREFERRED (when ACR_NAME is set): the Helm chart is imported into the private
# ACR server-side (Phase 3, `az acr import` from ghcr.io — Azure reaches ghcr.io
# even though we can't) and pulled from ACR (Phase 11). Everything — images AND
# chart — comes from the private registry. This is the standard enterprise OCI
# pattern and needs no firewall change.
# FALLBACK (no ACR, or ACR pull fails): fetch the chart from github.com directly
# (git clone / ZIP). We do NOT `oci://ghcr.io` install — the corporate firewall
# blocks the ghcr.io blob CDN (pkg-containers.githubusercontent.com).
# In BOTH cases the chart ends up as a LOCAL directory, so lint/install are
# identical downstream.
# ============================================================================
CHART_IN_ACR=false           # set true in Phase 3 once the chart is imported to ACR
LOCAL_CHART_DIR="$PROJECT_DIR/n8n-hosting/charts/n8n"
N8N_HOSTING_REPO="https://github.com/n8n-io/n8n-hosting.git"
# Chart URLs use N8N_CHART_VERSION (sourced from .env in Phase 1).
# Placeholder ${N8N_CHART_VERSION} gets expanded LATER (after .env loads).
# We re-derive the URLs in Phase 11 to ensure they pin to the tag, not main.
N8N_HOSTING_ZIP_BASE="https://github.com/n8n-io/n8n-hosting/archive/refs/tags"
N8N_HOSTING_ZIP_CODELOAD_BASE="https://codeload.github.com/n8n-io/n8n-hosting/zip/refs/tags"
CHART="$LOCAL_CHART_DIR"
CHART_SOURCE="local file path (./n8n-hosting/charts/n8n)"
# CHART_VERSION_EXPECTED is set in Phase 1 AFTER .env is sourced (uses N8N_CHART_VERSION).

# === Colors =============================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# === Helpers ============================================================
ok()      { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail()    { echo -e "  ${RED}[FAIL]${NC}  $1"; exit 1; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
info()    { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
section() {
  echo ""
  echo -e "${BLUE}${BOLD}===============================================================${NC}"
  echo -e "${BLUE}${BOLD} $1${NC}"
  echo -e "${BLUE}${BOLD}===============================================================${NC}"
}
portal() {
  echo ""
  echo -e "  ${YELLOW}${BOLD}>>> PORTAL ACTION NEEDED <<<${NC}"
  echo -e "$1"
  echo ""
}

# === Phase 1: Pre-flight ================================================
section "PHASE 1 / 13 — Pre-flight checks"

for tool in kubectl helm az openssl; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found"
  else
    fail "$tool not installed"
  fi
done

[ -f "$ENV_FILE" ] || fail ".env not found at $ENV_FILE  (run: cp .env.template .env, then fill in values)"

# Load .env
set -a
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
set +a
ok ".env loaded from $ENV_FILE"

# Now that .env is loaded, derive CHART_VERSION_EXPECTED (fallback to 1.10.1 if unset)
CHART_VERSION_EXPECTED="${N8N_CHART_VERSION:-1.10.1}"

# --- Non-interactive / CI mode ------------------------------------------------
# Auto-detected in Azure DevOps (TF_BUILD) / generic CI, or forced with
# N8N_DEPLOY_NONINTERACTIVE=1. In this mode: confirmation prompts auto-continue,
# and the DESTRUCTIVE clean-slate (helm uninstall + namespace delete) is SKIPPED —
# the deploy relies on `helm upgrade --install` idempotency so a pipeline run
# NEVER wipes a live release. Interactive local runs are unchanged.
NONINTERACTIVE=false
if [[ "${CI:-}" == "true" || -n "${TF_BUILD:-}" || "${N8N_DEPLOY_NONINTERACTIVE:-}" == "1" ]]; then
  NONINTERACTIVE=true
  info "Non-interactive/CI mode ON — prompts auto-continue; clean-slate wipe disabled."
fi

# Required vars
for v in AZURE_TENANT_ID AZURE_KEYVAULT_NAME RESOURCE_GROUP AKS_CLUSTER_NAME \
         AZURE_POSTGRES_HOST POSTGRES_DB_NAME POSTGRES_USERNAME POSTGRES_APP_USER \
         AZURE_REDIS_HOST AZURE_REDIS_PORT \
         N8N_IMAGE_TAG RUNNERS_IMAGE_TAG; do
  if [ -z "${!v:-}" ]; then
    fail "Required env var not set: $v  (see .env.template for defaults)"
  fi
done
ok "All required .env vars present"

# Guard: refuse to proceed if image tag is the mutable 'stable' tag or empty.
case "$N8N_IMAGE_TAG" in
  ""|"stable"|"latest")
    fail "N8N_IMAGE_TAG='$N8N_IMAGE_TAG' is not allowed. Set a pinned version like '2.29.9' in .env"
    ;;
esac
case "$RUNNERS_IMAGE_TAG" in
  ""|"stable"|"latest")
    fail "RUNNERS_IMAGE_TAG='$RUNNERS_IMAGE_TAG' is not allowed. Set a pinned version like '2.29.9' in .env"
    ;;
esac

# Derive image repositories from ACR_NAME (or fall back to Docker Hub)
ACR_NAME="${ACR_NAME:-}"
# Optional: ACR lives in a DIFFERENT subscription than this deployment (e.g. UAT
# reusing a shared non-prod ACR that sits in the DEV subscription). Set
# ACR_SUBSCRIPTION in .env to that ACR's subscription (name or id). Empty = the
# ACR is in the current subscription (the normal case). All `az acr ...` calls
# below get this flag so they target the right subscription; AKS attach uses the
# ACR's full resource id so it works cross-subscription/RG.
ACR_SUBSCRIPTION="${ACR_SUBSCRIPTION:-}"
ACR_SUB_ARGS=()
[ -n "$ACR_SUBSCRIPTION" ] && ACR_SUB_ARGS=(--subscription "$ACR_SUBSCRIPTION")
if [ -n "$ACR_NAME" ]; then
  ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
  N8N_IMAGE_REPOSITORY="${ACR_LOGIN_SERVER}/n8nio/n8n"
  RUNNERS_IMAGE_REPOSITORY="${ACR_LOGIN_SERVER}/n8nio/runners"
  ok "ACR enabled: pulling images from $ACR_LOGIN_SERVER${ACR_SUBSCRIPTION:+ (subscription: $ACR_SUBSCRIPTION)}"
else
  N8N_IMAGE_REPOSITORY="docker.io/n8nio/n8n"
  RUNNERS_IMAGE_REPOSITORY="docker.io/n8nio/runners"
  ok "ACR not set: pulling images from Docker Hub"
fi

# Guard: refuse to proceed if image repo points at the blocked registry.
case "$N8N_IMAGE_REPOSITORY" in
  *docker.n8n.io*)
    fail "N8N_IMAGE_REPOSITORY points at docker.n8n.io which is blocked by the corporate firewall. Use docker.io/n8nio/n8n or set ACR_NAME."
    ;;
esac
ok "Image config: $N8N_IMAGE_REPOSITORY:$N8N_IMAGE_TAG  (runners: $RUNNERS_IMAGE_REPOSITORY:$RUNNERS_IMAGE_TAG)"

# Derive public base URL from N8N_DOMAIN. n8n service is always ClusterIP (no
# LoadBalancer for n8n itself — see Phase 12) so without a domain there is no
# externally reachable URL; access is via kubectl port-forward (see validate.sh).
N8N_DOMAIN="${N8N_DOMAIN:-}"
N8N_TLS_SECRET_NAME="${N8N_TLS_SECRET_NAME:-n8n-tls}"
if [ -n "$N8N_DOMAIN" ]; then
  # Domain mode → HTTPS via ingress (force https regardless of .env to avoid cookie issues)
  N8N_PROTOCOL="${N8N_PROTOCOL:-https}"
  N8N_BASE_URL="${N8N_PROTOCOL}://${N8N_DOMAIN}"
  INGRESS_ENABLED="true"
  RENDER_DOMAIN="$N8N_DOMAIN"
  ok "Domain enabled: $N8N_BASE_URL (ingress=on, TLS secret=$N8N_TLS_SECRET_NAME)"
else
  # No domain → ClusterIP only, no external URL. WEBHOOK_URL stays blank;
  # reach n8n via: kubectl port-forward svc/<main> 5678:5678 -n n8n
  N8N_PROTOCOL="http"
  N8N_BASE_URL=""
  INGRESS_ENABLED="false"
  # Chart schema requires ingress.hosts[0].host to be non-empty even when
  # ingress.enabled=false. Use a placeholder hostname (never resolved or used).
  RENDER_DOMAIN="placeholder.invalid"
  info "Domain not set: ClusterIP-only topology (no LoadBalancer for n8n). WEBHOOK_URL left blank — use kubectl port-forward to reach n8n."
fi
export N8N_PROTOCOL N8N_BASE_URL INGRESS_ENABLED RENDER_DOMAIN

# Azure login
az account show >/dev/null 2>&1 || fail "Not logged in. Run: az login --tenant $AZURE_TENANT_ID"
CURRENT_TENANT=$(az account show --query tenantId -o tsv)
[ "$CURRENT_TENANT" = "$AZURE_TENANT_ID" ] || fail "Wrong tenant ($CURRENT_TENANT). Run: az login --tenant $AZURE_TENANT_ID"
ok "Azure logged in to tenant $AZURE_TENANT_ID"

# kubectl — force the active context to the .env cluster, then verify it.
# Guards against `az` and `kubectl` targeting DIFFERENT clusters (which silently
# deploys pods to the wrong cluster → identity/mount failures).
info "Setting kubectl context to .env cluster: $AKS_CLUSTER_NAME ..."
az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --overwrite-existing >/dev/null 2>&1 \
  || fail "Could not get credentials for $AKS_CLUSTER_NAME in $RESOURCE_GROUP. Check the names in .env + your Azure permissions."

kubectl cluster-info >/dev/null 2>&1 || fail "kubectl can't reach cluster $AKS_CLUSTER_NAME after get-credentials."

# Hard guard: verify the active context actually points at the .env cluster.
CURRENT_CTX=$(kubectl config current-context 2>/dev/null)
if [ "$CURRENT_CTX" != "$AKS_CLUSTER_NAME" ]; then
  # Context name may differ from cluster name if customized — verify by FQDN.
  CTX_FQDN=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  EXPECTED_FQDN=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query fqdn -o tsv 2>/dev/null)
  if [ -n "$EXPECTED_FQDN" ] && echo "$CTX_FQDN" | grep -q "$EXPECTED_FQDN"; then
    ok "kubectl context '$CURRENT_CTX' verified against $AKS_CLUSTER_NAME (FQDN match)"
  else
    fail "kubectl context MISMATCH.
       Active context: $CURRENT_CTX  ($CTX_FQDN)
       Expected:       $AKS_CLUSTER_NAME  ($EXPECTED_FQDN)
       deploy.sh would deploy to the WRONG cluster. Aborting.
       Fix: az aks get-credentials -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --overwrite-existing"
  fi
else
  ok "kubectl context confirmed: $CURRENT_CTX (matches .env)"
fi

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
ok "kubectl connected to AKS '$AKS_CLUSTER_NAME' ($NODE_COUNT nodes)"

# === Phase 2: Auto-detect AKS kubelet identity ==========================
section "PHASE 2 / 13 — Detect AKS kubelet identity"

info "Reading kubelet identity from $AKS_CLUSTER_NAME ..."
KUBELET_CID=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" \
  --query "identityProfile.kubeletidentity.clientId" -o tsv 2>/dev/null)

if [ -z "$KUBELET_CID" ] || [ "$KUBELET_CID" = "null" ]; then
  fail "Could not read kubelet identity. Check AKS cluster name + RG, or your Azure permissions."
fi
ok "Kubelet identity Client ID: $KUBELET_CID"

# Persist to .env (idempotent)
if grep -q '^KUBELET_IDENTITY_CLIENT_ID=' "$ENV_FILE"; then
  sed -i "s|^KUBELET_IDENTITY_CLIENT_ID=.*|KUBELET_IDENTITY_CLIENT_ID=\"$KUBELET_CID\"|" "$ENV_FILE"
else
  echo "KUBELET_IDENTITY_CLIENT_ID=\"$KUBELET_CID\"" >> "$ENV_FILE"
fi
export KUBELET_IDENTITY_CLIENT_ID="$KUBELET_CID"
ok "Saved KUBELET_IDENTITY_CLIENT_ID to .env"

# === Phase 2b: Verify Secrets Store CSI driver ==============================
# Catch + self-heal CSI issues early (addon disabled, or DaemonSet unhealthy on
# a node) instead of failing late in Phase 8 with a misleading mount error.
section "PHASE 2b — Verify Secrets Store CSI driver"

# 1. Ensure the AKS addon is enabled (auto-enable if not)
CSI_ADDON=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" \
  --query "addonProfiles.azureKeyvaultSecretsProvider.enabled" -o tsv 2>/dev/null)
if [ "$CSI_ADDON" = "true" ]; then
  ok "AKS addon 'azure-keyvault-secrets-provider' is enabled"
else
  warn "AKS addon 'azure-keyvault-secrets-provider' is NOT enabled — enabling now..."
  if az aks enable-addons -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" \
       --addons azure-keyvault-secrets-provider -o none 2>/dev/null; then
    ok "Addon enabled (driver pods will roll out in ~1-2 min)"
  else
    fail "Could not enable the addon automatically. Ask the Azure team to run:
       az aks enable-addons -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --addons azure-keyvault-secrets-provider"
  fi
fi

# 2. Ensure the CSI driver DaemonSet is healthy on ALL nodes.
#    A node added/reimaged after the last deploy can be missing the driver pod,
#    which produces the "driver not registered" error for any pod on that node.
info "Checking CSI driver DaemonSet health (DESIRED == READY on every node)..."
CSI_DS=$(kubectl get ds -n kube-system -o name 2>/dev/null | grep -i secrets-store | head -1)
if [ -z "$CSI_DS" ]; then
  info "CSI DaemonSet not visible yet (addon may still be rolling out). Waiting up to 3 min..."
  for i in {1..18}; do
    CSI_DS=$(kubectl get ds -n kube-system -o name 2>/dev/null | grep -i secrets-store | head -1)
    [ -n "$CSI_DS" ] && break
    sleep 10
  done
fi

if [ -n "$CSI_DS" ]; then
  # Wait for DESIRED == READY
  HEALTHY=false
  for i in {1..18}; do
    DESIRED=$(kubectl get "$CSI_DS" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    READY=$(kubectl get "$CSI_DS" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
    if [ -n "$DESIRED" ] && [ "$DESIRED" = "$READY" ] && [ "$DESIRED" -gt 0 ]; then
      HEALTHY=true
      break
    fi
    info "CSI driver: $READY/$DESIRED nodes ready — waiting..."
    sleep 10
  done

  if [ "$HEALTHY" = "true" ]; then
    ok "CSI driver DaemonSet healthy ($READY/$DESIRED nodes)"
  else
    warn "CSI driver DaemonSet NOT fully ready ($READY/$DESIRED). Restarting it..."
    kubectl rollout restart "$CSI_DS" -n kube-system >/dev/null 2>&1 || true
    kubectl rollout restart ds -n kube-system -l app=csi-secrets-store-provider-azure >/dev/null 2>&1 || true
    if kubectl rollout status "$CSI_DS" -n kube-system --timeout=180s >/dev/null 2>&1; then
      ok "CSI driver DaemonSet healthy after restart"
    else
      fail "CSI driver DaemonSet still unhealthy after restart. A node may be broken.
       Diagnose:  kubectl get pods -n kube-system -o wide | grep secrets-store
       Or reinstall the addon:
         az aks disable-addons -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --addons azure-keyvault-secrets-provider
         az aks enable-addons  -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --addons azure-keyvault-secrets-provider"
    fi
  fi
else
  fail "Secrets Store CSI driver DaemonSet not found in kube-system after waiting.
       The addon enable may have failed. Check:
         az aks show -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --query addonProfiles.azureKeyvaultSecretsProvider"
fi

# 3. Confirm the CSI driver is registered (the exact thing the mount error checks)
if kubectl get csidrivers 2>/dev/null | grep -q "secrets-store.csi.k8s.io"; then
  ok "CSI driver 'secrets-store.csi.k8s.io' is registered"
else
  warn "CSI driver 'secrets-store.csi.k8s.io' not registered yet — may need another minute"
fi

# 4. Resolve the CSI driver's Key Vault identity. The addon creates a dedicated
#    identity (azurekeyvaultsecretsprovider-<cluster>) wired to the node VMSS —
#    Microsoft's recommended identity for the SPC. Fall back to kubelet identity.
info "Resolving CSI driver identity for Key Vault access..."
ADDON_CLIENT_ID=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" \
  --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv 2>/dev/null)
ADDON_OBJECT_ID=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" \
  --query "addonProfiles.azureKeyvaultSecretsProvider.identity.objectId" -o tsv 2>/dev/null)

if [ -n "$ADDON_CLIENT_ID" ] && [ "$ADDON_CLIENT_ID" != "null" ]; then
  CSI_IDENTITY_CLIENT_ID="$ADDON_CLIENT_ID"
  CSI_IDENTITY_OBJECT_ID="$ADDON_OBJECT_ID"
  ok "Using CSI addon identity (client ID: $CSI_IDENTITY_CLIENT_ID)"
else
  # Fallback: addon identity not exposed → use kubelet identity (old behaviour)
  CSI_IDENTITY_CLIENT_ID="$KUBELET_CID"
  CSI_IDENTITY_OBJECT_ID="$KUBELET_CID"   # az resolves client ID for role assignment
  warn "Addon identity not found — falling back to kubelet identity ($KUBELET_CID)"
fi
export CSI_IDENTITY_CLIENT_ID CSI_IDENTITY_OBJECT_ID

# === Phase 3: ACR image import (if ACR_NAME is set) ====================
section "PHASE 3 / 13 — ACR image import"

if [ -n "$ACR_NAME" ]; then
  # Verify ACR exists + grab its full resource id (also serves as the existence check).
  # --subscription targets the ACR's subscription when it's not the current one.
  ACR_ID=$(az acr show -n "$ACR_NAME" "${ACR_SUB_ARGS[@]}" --query id -o tsv 2>/dev/null)
  if [ -z "$ACR_ID" ]; then
    fail "ACR '$ACR_NAME' not found${ACR_SUBSCRIPTION:+ in subscription '$ACR_SUBSCRIPTION'}.
       If the ACR lives in a DIFFERENT subscription (e.g. UAT reusing a shared non-prod
       ACR in the DEV subscription), set ACR_SUBSCRIPTION in .env to that subscription
       (name or id). Otherwise verify ACR_NAME, have the Azure team create it, or leave
       ACR_NAME empty to pull from docker.io."
  fi
  ok "ACR '$ACR_NAME' exists"

  # Attach AKS to the ACR (grants the kubelet identity AcrPull). Use the ACR's full
  # resource id so this works even when the ACR is in another subscription/RG. NOTE:
  # cross-subscription attach still needs the running identity to have role-assignment
  # rights on the ACR — if this line can't grant it, pre-grant AcrPull to the AKS
  # agentpool identity on the ACR in the Portal.
  info "Ensuring AKS is attached to ACR (AcrPull role)..."
  az aks update -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --attach-acr "$ACR_ID" -o none 2>/dev/null || true
  ok "AKS attached to ACR"

  # Import images from Docker Hub → ACR (server-side, no Docker daemon needed)
  # az acr import is idempotent — if image:tag already exists, it's a no-op.
  IMAGES_TO_IMPORT=(
    "docker.io/n8nio/n8n:$N8N_IMAGE_TAG|n8nio/n8n:$N8N_IMAGE_TAG"
    "docker.io/n8nio/runners:$RUNNERS_IMAGE_TAG|n8nio/runners:$RUNNERS_IMAGE_TAG"
  )

  for entry in "${IMAGES_TO_IMPORT[@]}"; do
    SRC="${entry%%|*}"
    DST="${entry##*|}"

    # Check if image already exists in ACR
    TAG="${DST##*:}"
    REPO="${DST%%:*}"
    EXISTS=$(az acr repository show-tags -n "$ACR_NAME" "${ACR_SUB_ARGS[@]}" --repository "$REPO" --query "[?@=='$TAG']" -o tsv 2>/dev/null || echo "")

    if [ -n "$EXISTS" ]; then
      ok "Already in ACR: $DST"
    else
      info "Importing $SRC → $ACR_LOGIN_SERVER/$DST ..."
      if az acr import -n "$ACR_NAME" "${ACR_SUB_ARGS[@]}" --source "$SRC" --image "$DST" --no-wait 2>&1; then
        ok "Imported: $DST"
      else
        warn "Import failed for $SRC — AKS will pull from Docker Hub as fallback."
        warn "Manually import later:  az acr import -n $ACR_NAME --source $SRC --image $DST"
      fi
    fi
  done

  ok "ACR image import complete"

  # Import the Helm CHART (OCI artifact) into ACR too, so we install from the
  # private registry instead of fetching from github.com. az acr import runs
  # server-side (Azure → ghcr.io), so it works even though ghcr.io is blocked here.
  CHART_ACR_REPO="helm/n8n"
  CHART_ACR_TAG="$CHART_VERSION_EXPECTED"
  if az acr repository show-tags -n "$ACR_NAME" "${ACR_SUB_ARGS[@]}" --repository "$CHART_ACR_REPO" --query "[?@=='$CHART_ACR_TAG']" -o tsv 2>/dev/null | grep -q .; then
    ok "Helm chart already in ACR: $CHART_ACR_REPO:$CHART_ACR_TAG"
    CHART_IN_ACR=true
  else
    info "Importing Helm chart ghcr.io/n8n-io/n8n-helm-chart/n8n:$CHART_ACR_TAG → $ACR_LOGIN_SERVER/$CHART_ACR_REPO:$CHART_ACR_TAG ..."
    if az acr import -n "$ACR_NAME" "${ACR_SUB_ARGS[@]}" --source "ghcr.io/n8n-io/n8n-helm-chart/n8n:$CHART_ACR_TAG" --image "$CHART_ACR_REPO:$CHART_ACR_TAG" 2>&1; then
      ok "Helm chart imported to ACR"
      CHART_IN_ACR=true
    else
      warn "Chart import to ACR failed — will fall back to fetching the chart from github.com (Phase 11)."
      CHART_IN_ACR=false
    fi
  fi
else
  info "ACR_NAME not set in .env → pulling images from Docker Hub + chart from github.com."
  info "To use ACR (recommended): set ACR_NAME in .env and re-run — images AND chart come from the private registry."
fi

# === Phase 4: Verify KeyVault secrets ===================================
section "PHASE 4 / 13 — Verify KeyVault secrets"

# Note: N8N_PROTOCOL is derived from .env and rendered into values-enterprise.yaml
# via the <N8N_PROTOCOL> placeholder. The KV n8n-protocol secret was historically
# the source — kept for backward compatibility but values-file path takes precedence.

REQUIRED_SECRETS=(
  "n8n-encryption-key"
  "n8n-host"
  "n8n-port"
  "n8n-protocol"
  "n8n-db-password"
  "n8n-db-app-user"
  "n8n-db-app-password"
  "n8n-redis-password"
  "n8n-runner-auth-token"
)
# Optional: if absent, deploy.sh degrades to single-main (no HA).
OPTIONAL_SECRETS=(
  "n8n-license-key"
)

# License detection — three paths satisfy "license available":
#   1. N8N_LICENSE_KEY in .env (we inject via --set license.activationKey)
#   2. LICENSE_ACTIVATED=true in .env (user activated via UI already)
#   3. KV has n8n-license-key secret (detected later in this phase)
LICENSE_AVAILABLE="false"
LICENSE_VIA_KEY="false"
if [ -n "${N8N_LICENSE_KEY:-}" ]; then
  LICENSE_AVAILABLE="true"
  LICENSE_VIA_KEY="true"
  ok "N8N_LICENSE_KEY found in .env → multi-main HA enabled (auto-activates on deploy)"
elif [ "${LICENSE_ACTIVATED:-false}" = "true" ]; then
  LICENSE_AVAILABLE="true"
  ok "LICENSE_ACTIVATED=true in .env → multi-main HA enabled (UI-activated)"
fi
export LICENSE_VIA_KEY

info "Listing secrets in $AZURE_KEYVAULT_NAME ..."
ACTUAL_SECRETS=$(az keyvault secret list --vault-name "$AZURE_KEYVAULT_NAME" --query "[].name" -o tsv 2>/dev/null || echo "")

if [ -z "$ACTUAL_SECRETS" ]; then
  warn "Could not list KV secrets from this jumpbox (firewall/permission)."
  info "This is OK — the AKS cluster will reach KV via private endpoint."
  info "Skipping name verification. Make sure admin populated all required secrets:"
  for s in "${REQUIRED_SECRETS[@]}"; do echo "    - $s"; done
  echo "  Optional (multi-main HA needs this):"
  for s in "${OPTIONAL_SECRETS[@]}"; do echo "    - $s"; done
  echo ""
  if [ "$NONINTERACTIVE" = true ]; then
    info "CI mode: assuming required KV secrets are present (seeded before the pipeline; LICENSE_AVAILABLE from .env)."
  else
    read -p "Are all REQUIRED secrets present in KeyVault? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted. Have admin add missing secrets, then re-run."
    read -p "Is the LICENSE secret (n8n-license-key) also present? [y/N] " ans2
    [[ "$ans2" =~ ^[Yy]$ ]] && LICENSE_AVAILABLE="true"
  fi
else
  MISSING_REQUIRED=()
  for s in "${REQUIRED_SECRETS[@]}"; do
    if echo "$ACTUAL_SECRETS" | grep -qx "$s"; then
      ok "Found:    $s"
    else
      MISSING_REQUIRED+=("$s")
      warn "MISSING:  $s"
    fi
  done

  for s in "${OPTIONAL_SECRETS[@]}"; do
    if echo "$ACTUAL_SECRETS" | grep -qx "$s"; then
      ok "Found:    $s  (optional)"
      [ "$s" = "n8n-license-key" ] && LICENSE_AVAILABLE="true"
    else
      info "Optional: $s NOT present — multi-main HA will be disabled"
    fi
  done

  if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
    echo ""
    warn "${#MISSING_REQUIRED[@]} REQUIRED secret(s) missing in KeyVault."
    portal "Portal → Key vaults → $AZURE_KEYVAULT_NAME → Objects → Secrets → + Generate/Import\n  Add each missing secret with the EXACT name shown above."
    if [ "$NONINTERACTIVE" = true ]; then
      fail "CI mode: ${#MISSING_REQUIRED[@]} required KV secret(s) missing — seed them before the pipeline runs."
    fi
    read -p "Done? Re-checked? Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted. Add missing secrets, then re-run."
  fi
fi

if [ "$LICENSE_AVAILABLE" = "true" ]; then
  ok "License key present in KV → multi-main HA will be enabled"
else
  warn "License key absent from KV → SINGLE-MAIN mode (no HA)"
  warn "  Add 'n8n-license-key' secret in KV later + re-run to enable multi-main"
fi
export LICENSE_AVAILABLE

# === Phase 5: Grant CSI driver identity access to KV ====================
section "PHASE 5 / 13 — Grant CSI identity access to KeyVault"

KV_ID=$(az keyvault show --name "$AZURE_KEYVAULT_NAME" --query id -o tsv 2>/dev/null) \
  || fail "Cannot read KeyVault $AZURE_KEYVAULT_NAME (check name or your Azure permissions)"

# Grant to the CSI driver identity resolved in Phase 2b (addon identity, or
# kubelet identity as fallback). This is the identity the SecretProviderClass
# uses to authenticate to Key Vault.
# Auto-detect KV authorization mode (RBAC vs legacy Access Policy).
KV_RBAC=$(az keyvault show --name "$AZURE_KEYVAULT_NAME" \
  --query "properties.enableRbacAuthorization" -o tsv 2>/dev/null || echo "true")

if [ "$KV_RBAC" = "true" ]; then
  # RBAC mode → assign "Key Vault Secrets User" role
  EXISTING=$(az role assignment list \
    --assignee "$CSI_IDENTITY_OBJECT_ID" \
    --scope "$KV_ID" \
    --query "[?roleDefinitionName=='Key Vault Secrets User'] | length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$EXISTING" -gt 0 ]; then
    ok "Role 'Key Vault Secrets User' already assigned to CSI identity"
  else
    info "Assigning 'Key Vault Secrets User' to CSI identity ($CSI_IDENTITY_CLIENT_ID)..."
    if az role assignment create \
         --assignee "$CSI_IDENTITY_OBJECT_ID" \
         --role "Key Vault Secrets User" \
         --scope "$KV_ID" >/dev/null 2>&1; then
      ok "Role assigned"
      info "Waiting 30s for RBAC propagation ..."
      sleep 30
    else
      warn "Could not assign role automatically (insufficient permissions)."
      portal "Portal → Key vaults → $AZURE_KEYVAULT_NAME → Access control (IAM)\n  + Add → Add role assignment\n  Role:    Key Vault Secrets User\n  Members: Managed identity → search Object ID:\n           $CSI_IDENTITY_OBJECT_ID\n  Review + assign"
      read -p "Done in portal? Press ENTER to continue..." _
    fi
  fi
else
  # Legacy Access Policy mode → set-policy with get/list secret permissions
  EXISTING=$(az keyvault show --name "$AZURE_KEYVAULT_NAME" \
    --query "properties.accessPolicies[?objectId=='$CSI_IDENTITY_OBJECT_ID'].permissions.secrets" -o tsv 2>/dev/null)
  if echo "$EXISTING" | grep -q "get"; then
    ok "CSI identity already has get/list on KV (access-policy mode)"
  else
    info "Granting get/list secret permissions to CSI identity (access-policy mode)..."
    if az keyvault set-policy --name "$AZURE_KEYVAULT_NAME" \
         --object-id "$CSI_IDENTITY_OBJECT_ID" \
         --secret-permissions get list -o none 2>/dev/null; then
      ok "Access policy granted"
      sleep 10
    else
      warn "Could not set access policy automatically (insufficient permissions)."
      portal "Portal → Key vaults → $AZURE_KEYVAULT_NAME → Access policies\n  + Create → Secret: Get + List\n  Principal: search Object ID $CSI_IDENTITY_OBJECT_ID\n  Create"
      read -p "Done in portal? Press ENTER to continue..." _
    fi
  fi
fi

# === Phase 5b: Prepare Azure Blob Storage access (IAM grant + container) ====
# Only runs if AZURE_STORAGE_ACCOUNT is set in .env (Azure Blob binary/execution
# storage mode — see Phase 7's storage-mode auto-switch). n8n's pods use
# DefaultAzureCredential with no Workload Identity federation configured, so at
# runtime they authenticate as the AKS *kubelet* identity (node-level, via IMDS —
# the same identity Phase 2b falls back to for KV), NOT the CSI addon identity
# (that one is scoped to Key Vault only). Two things are required and neither
# exists until this phase creates them: (1) the IAM role grant, (2) the target
# container itself — deploy.sh does not provision the storage account, only what
# lives inside it. Miss either one and writes fail (403, or container-not-found)
# silently at runtime, not at deploy time.
section "PHASE 5b — Prepare Blob Storage access (Azure Blob external storage)"

if [ -n "${AZURE_STORAGE_ACCOUNT:-}" ]; then
  STORAGE_ID=$(az storage account show --name "$AZURE_STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null)
  if [ -z "$STORAGE_ID" ]; then
    # Storage account may live in a different resource group than $RESOURCE_GROUP
    STORAGE_ID=$(az resource list --name "$AZURE_STORAGE_ACCOUNT" --resource-type Microsoft.Storage/storageAccounts --query "[0].id" -o tsv 2>/dev/null)
  fi

  if [ -z "$STORAGE_ID" ]; then
    warn "Cannot find Storage Account '$AZURE_STORAGE_ACCOUNT' (check the name in .env, or your Azure permissions)."
    portal "Portal → Storage accounts → confirm '$AZURE_STORAGE_ACCOUNT' exists,\n  then re-run deploy.sh once it's reachable."
  else
    EXISTING_BLOB_ROLE=$(az role assignment list \
      --assignee "$KUBELET_IDENTITY_CLIENT_ID" \
      --scope "$STORAGE_ID" \
      --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" -o tsv 2>/dev/null || echo "0")

    if [ "$EXISTING_BLOB_ROLE" -gt 0 ]; then
      ok "Role 'Storage Blob Data Contributor' already assigned to kubelet identity"
    else
      info "Assigning 'Storage Blob Data Contributor' to kubelet identity ($KUBELET_IDENTITY_CLIENT_ID)..."
      if az role assignment create \
           --assignee "$KUBELET_IDENTITY_CLIENT_ID" \
           --role "Storage Blob Data Contributor" \
           --scope "$STORAGE_ID" >/dev/null 2>&1; then
        ok "Role assigned"
        info "Waiting 30s for RBAC propagation ..."
        sleep 30
      else
        warn "Could not assign role automatically (insufficient permissions)."
        portal "Portal → Storage accounts → $AZURE_STORAGE_ACCOUNT → Access control (IAM)\n  + Add → Add role assignment\n  Role:    Storage Blob Data Contributor\n  Members: Managed identity → search Client ID:\n           $KUBELET_IDENTITY_CLIENT_ID\n  Review + assign"
        read -p "Done in portal? Press ENTER to continue..." _
      fi
    fi

    # deploy.sh provisions neither the storage account nor its containers — only
    # the IAM grant above. Ensure the target container exists, since n8n calls
    # container.exists() at startup and hard-fails ("Failed to connect to Azure
    # Blob storage") if it's missing.
    #
    # IMPORTANT: use the CONTROL PLANE (management.azure.com / ARM) to create the
    # container, NOT the data plane (`az storage container create`). Production
    # storage accounts here are private-endpoint-only with public access disabled,
    # so the data plane (<acct>.blob.core.windows.net) is unreachable from this
    # jumpbox — a data-plane create just times out. The ARM path works regardless
    # of the storage firewall (it only needs Microsoft.Storage/.../containers/write,
    # i.e. Contributor / Storage Account Contributor on the account).
    BLOB_CONTAINER="${AZURE_STORAGE_CONTAINER:-n8n-data}"
    CONTAINER_ARM="https://management.azure.com${STORAGE_ID}/blobServices/default/containers/${BLOB_CONTAINER}?api-version=2023-01-01"
    if az rest --method GET --url "$CONTAINER_ARM" -o none 2>/dev/null; then
      ok "Blob container '$BLOB_CONTAINER' already exists"
    else
      info "Creating Blob container '$BLOB_CONTAINER' (control-plane / ARM)..."
      if az rest --method PUT --url "$CONTAINER_ARM" --body '{}' -o none 2>/dev/null; then
        ok "Container '$BLOB_CONTAINER' created"
      else
        warn "Could not create container automatically (need Contributor / Storage Account Contributor on the account)."
        portal "Portal → Storage accounts → $AZURE_STORAGE_ACCOUNT → Data storage → Containers\n  + Container → Name: $BLOB_CONTAINER → Create"
        read -p "Done in portal? Press ENTER to continue..." _
      fi
    fi
  fi
else
  info "AZURE_STORAGE_ACCOUNT not set — skipping Blob Storage role grant + container check (database mode)."
fi

# === Phase 6: Cleanup old K8s state =====================================
section "PHASE 6 / 13 — Clean slate (delete old n8n)"

if [ "$NONINTERACTIVE" = true ]; then
  info "CI mode: skipping clean-slate. Existing release/namespace kept; 'helm upgrade --install' applies changes in place (no wipe)."
elif helm list -n "$NAMESPACE" 2>/dev/null | grep -q "$RELEASE_NAME"; then
  warn "Found existing Helm release '$RELEASE_NAME' — uninstalling..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait 2>/dev/null || true
  ok "Helm release removed"
fi

if [ "$NONINTERACTIVE" = true ]; then
  :   # namespace kept in CI (created below if absent)
elif kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  warn "Namespace '$NAMESPACE' exists. Deleting it wipes ALL n8n state in K8s."
  echo ""
  read -p "Type 'yes' to delete namespace and start clean: " confirm
  [ "$confirm" = "yes" ] || fail "Aborted (you said no to clean slate)"
  kubectl delete namespace "$NAMESPACE" --wait=true --timeout=180s
  ok "Namespace deleted"
else
  ok "No old namespace to clean — already a clean slate"
fi

# === Phase 7: Render config templates =====================================
section "PHASE 7 / 13 — Render config templates from .env"

# Renders template files → working copies.  Originals are NEVER modified,
# so the same repo works across DEV / UAT / TEST / PROD — just change .env.

_render() {
  local src="$1" dst="$2"
  cp "$src" "$dst"
  for placeholder in "${!ENV_MAP[@]}"; do
    sed -i "s|$placeholder|${ENV_MAP[$placeholder]}|g" "$dst"
  done
}

# Environment name (dev | uat | prod) — the real per-deployment variable. Used for
# the namespace 'environment' label. Defaults to "dev" if unset.
ENVIRONMENT="${ENVIRONMENT:-dev}"

# --- Binary + execution data storage (AUTO: Azure Blob if configured, else database) ---
# n8n does NOT support 'filesystem' mode in queue mode (n8n docs), so the non-Blob
# fallback is 'database' (data in PostgreSQL). Set AZURE_STORAGE_ACCOUNT in .env to
# offload binary + execution data to Azure Blob via the pod's managed identity.
# (N8N_AVAILABLE_BINARY_DATA_MODES is deprecated in n8n >= 2.29 and no longer set.)
if [ -n "${AZURE_STORAGE_ACCOUNT:-}" ]; then
  # HARD VERSION GATE: the 'azure' binary-data mode only exists in n8n >= 2.29.0.
  # 2.27.x / 2.28.x reject it as an invalid enum and the pods crash-loop with
  # "Failed to connect to Azure Blob storage".
  if [ "$(printf '%s\n2.29.0\n' "$N8N_IMAGE_TAG" | sort -V | head -1)" != "2.29.0" ]; then
    fail "Azure Blob storage requires n8n >= 2.29.0, but N8N_IMAGE_TAG='$N8N_IMAGE_TAG'.
       Bump N8N_IMAGE_TAG + RUNNERS_IMAGE_TAG in .env (e.g. 2.29.9), or clear
       AZURE_STORAGE_ACCOUNT to stay in database mode."
  fi
  BINARY_DATA_MODE="azure"; EXECUTION_DATA_STORAGE_MODE="azure"
  info "External storage: Azure Blob (account '${AZURE_STORAGE_ACCOUNT}', managed identity — no keys)."
else
  BINARY_DATA_MODE="database"; EXECUTION_DATA_STORAGE_MODE="database"
  info "External storage: none configured — binary + execution data in PostgreSQL (database mode)."
fi

declare -A ENV_MAP=(
  ["<AZURE_TENANT_ID>"]="$AZURE_TENANT_ID"
  # SPC identity placeholder → CSI driver identity resolved in Phase 2b
  # (addon identity preferred, kubelet identity as fallback).
  ["<KUBELET_IDENTITY_CLIENT_ID>"]="$CSI_IDENTITY_CLIENT_ID"
  ["<AZURE_KEYVAULT_NAME>"]="$AZURE_KEYVAULT_NAME"
  ["<AZURE_POSTGRES_HOST>"]="$AZURE_POSTGRES_HOST"
  ["<POSTGRES_DB_NAME>"]="$POSTGRES_DB_NAME"
  ["<POSTGRES_USERNAME>"]="$POSTGRES_USERNAME"
  ["<POSTGRES_APP_USER>"]="$POSTGRES_APP_USER"
  ["<AZURE_REDIS_HOST>"]="$AZURE_REDIS_HOST"
  ["<AZURE_REDIS_PORT>"]="$AZURE_REDIS_PORT"
  ["<N8N_IMAGE_TAG>"]="$N8N_IMAGE_TAG"
  ["<RUNNERS_IMAGE_TAG>"]="$RUNNERS_IMAGE_TAG"
  ["<N8N_DOMAIN>"]="$RENDER_DOMAIN"
  ["<N8N_PROTOCOL>"]="$N8N_PROTOCOL"
  ["<N8N_TLS_SECRET_NAME>"]="$N8N_TLS_SECRET_NAME"
  ["<N8N_BASE_URL>"]="$N8N_BASE_URL"
  ["<N8N_TIMEZONE>"]="${N8N_TIMEZONE:-UTC}"
  ["<N8N_SSO_LOGIN_LABEL>"]="${N8N_SSO_LOGIN_LABEL:-Sign in with SSO}"
  ["<BINARY_DATA_MODE>"]="${BINARY_DATA_MODE:-database}"
  ["<EXECUTION_DATA_STORAGE_MODE>"]="${EXECUTION_DATA_STORAGE_MODE:-database}"
  ["<AZURE_STORAGE_ACCOUNT>"]="${AZURE_STORAGE_ACCOUNT:-}"
  ["<AZURE_STORAGE_CONTAINER>"]="${AZURE_STORAGE_CONTAINER:-n8n-data}"
  # Kubelet identity for the pods' DefaultAzureCredential (Blob storage). NOT the
  # CSI identity — <KUBELET_IDENTITY_CLIENT_ID> above resolves to the CSI addon
  # identity for the SPC; this one is the actual node/kubelet identity that
  # Phase 5b granted Blob access to.
  ["<POD_IDENTITY_CLIENT_ID>"]="${KUBELET_IDENTITY_CLIENT_ID:-}"
)

info "Rendering values-enterprise.yaml ..."
_render "$VALUES_TEMPLATE" "$VALUES_FILE"

# Guard: if webhook.url renders to literal "/" (happens when N8N_BASE_URL is empty),
# remove the line so chart falls back to auto-deriving WEBHOOK_URL from service.
if grep -q '^\s\+url:\s*"/"\s*$' "$VALUES_FILE"; then
  sed -i '/^\s\+url:\s*"\/"\s*$/d' "$VALUES_FILE"
  warn "webhook.url was empty — removed so chart auto-derives WEBHOOK_URL"
fi

# Verify no unfilled placeholders remain in active (non-comment) lines
# FAIL on unsubstituted placeholders — they would be sent to Helm as literal
# strings (e.g. image.tag=<N8N_IMAGE_TAG>) causing manifest unknown errors.
# Count remaining placeholders. Use grep -o | wc -l (grep -c emits "0" AND
# exits 1 on no-match, which combined with `|| echo 0` produced "0\n0" → the
# "integer expression expected" error. wc -l always emits a clean single int.)
REMAINING=$(grep -v '^\s*#' "$VALUES_FILE" | grep -o '<[A-Z_][A-Z0-9_]*>' | wc -l | tr -d '[:space:]')
if [ "${REMAINING:-0}" -gt 0 ]; then
  warn "$REMAINING unfilled placeholder(s) in rendered values:"
  grep -n '<[A-Z_][A-Z0-9_]*>' "$VALUES_FILE" | grep -v '^\s*#' | head -10
  fail "Unsubstituted placeholders found. Check .env for missing keys, then re-run."
fi
ok "values-enterprise-rendered.yaml (all placeholders resolved)"

info "Rendering secret-provider-class.yaml ..."
_render "$SPC_TEMPLATE" "$SPC_FILE"

# If license key isn't in KV, strip its entries so the CSI mount doesn't 404.
if [ "$LICENSE_AVAILABLE" != "true" ]; then
  info "License absent — removing n8n-license-key entries from rendered SPC..."

  # 1) Strip the `secretObjects:` block for n8n-license-secret
  #    Range: from the secretName line through the (unique) "key: license-key" line.
  sed -i '/- secretName: n8n-license-secret/,/key: license-key/d' "$SPC_FILE"

  # 2) Strip the `objects:` array entry for n8n-license-key
  #    The block is 4 lines: "- |", objectName, objectType, objectAlias.
  #    Reverse the file → match the (unique) "objectAlias: license-key" line +
  #    3 lines after (which were before in original order: objectType, objectName, "- |").
  #    Then reverse back. tac is bundled with git bash GNU coreutils.
  if command -v tac >/dev/null 2>&1; then
    tac "$SPC_FILE" | sed '/objectAlias: license-key/,+3d' | tac > "$SPC_FILE.tmp" \
      && mv "$SPC_FILE.tmp" "$SPC_FILE"
  else
    # macOS/BSD fallback (no tac): use awk reverse
    awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' "$SPC_FILE" \
      | sed '/objectAlias: license-key/,+3d' \
      | awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' \
      > "$SPC_FILE.tmp" && mv "$SPC_FILE.tmp" "$SPC_FILE"
  fi

  # Verify strip worked
  if grep -q "n8n-license-key\|n8n-license-secret" "$SPC_FILE"; then
    fail "Failed to strip license entries from $SPC_FILE. Inspect the file and remove manually."
  fi
  ok "Stripped license entries from secret-provider-class-rendered.yaml"
fi

ok "secret-provider-class-rendered.yaml"

# === Phase 8: Bootstrap K8s resources ===================================
section "PHASE 8 / 13 — Create K8s resources (namespace, SA, SPC, sync pod)"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - \
  || fail "Failed to create/ensure namespace $NAMESPACE"
kubectl label namespace "$NAMESPACE" app=n8n environment=${ENVIRONMENT} --overwrite >/dev/null \
  || warn "Could not label namespace $NAMESPACE (non-fatal)"
ok "Namespace '$NAMESPACE' created"

kubectl create serviceaccount n8n-enterprise -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || fail "Failed to create/ensure serviceaccount n8n-enterprise"
ok "ServiceAccount 'n8n-enterprise' created"

kubectl apply -f "$SPC_FILE" >/dev/null \
  || fail "Failed to apply SecretProviderClass ($SPC_FILE) — CSI secret sync will not work"
ok "SecretProviderClass applied"

kubectl apply -f "$PROJECT_DIR/azure/secret-provider-pod.yaml" >/dev/null
ok "CSI secret-keeper Deployment applied"

# Allow managed-identity IMDS egress when using Azure Blob storage. The chart's own
# NetworkPolicy blocks the IMDS token endpoint (169.254.169.254:80), which makes
# DefaultAzureCredential time out → "Failed to connect to Azure Blob storage". This
# additive policy opens ONLY that. Harmless/skipped in database mode.
if [ -n "${AZURE_STORAGE_ACCOUNT:-}" ]; then
  kubectl apply -f "$PROJECT_DIR/azure/networkpolicy-imds.yaml" >/dev/null \
    && ok "IMDS egress NetworkPolicy applied (managed identity → Azure Blob)" \
    || warn "Could not apply IMDS egress NetworkPolicy — managed-identity Blob auth may fail"
fi
info "Waiting for keeper pod to become Ready (up to 3 min)..."

# Wait for the Deployment to be Ready — this guarantees the CSI mount
# succeeded, which means the K8s Secret objects are populated.
if ! kubectl rollout status deployment/n8n-secret-sync -n "$NAMESPACE" --timeout=180s; then
  warn "Secret-keeper Deployment did not become Ready. Diagnostics:"
  kubectl get pods -n "$NAMESPACE" -l app=n8n-secret-sync 2>&1 | tail -10
  echo ""
  kubectl describe pods -n "$NAMESPACE" -l app=n8n-secret-sync 2>&1 | tail -50
  echo ""
  fail "CSI mount failed. Possible causes:
       1. CSI identity ($CSI_IDENTITY_CLIENT_ID) lacks Key Vault read access
          (check: az role assignment list --assignee $CSI_IDENTITY_OBJECT_ID --scope $KV_ID)
          → Phase 5 grants this automatically; if it warned, grant it in Portal.
       2. 'requested identity isn't assigned to this resource' / 'Identity not found'
          → the SPC userAssignedIdentityID isn't on the node VMSS. Phase 2b now
            uses the CSI addon identity; if you see this, the addon identity may
            still be propagating — wait 2 min and re-run.
       3. Key Vault firewall blocks the cluster — allow the AKS subnet / private endpoint.
       4. A KV secret name in secret-provider-class.yaml doesn't exist in KV."
fi
ok "Secret-keeper pod is Ready — CSI mount successful"

# Now verify every expected K8s Secret actually exists.
EXPECTED_K8S_SECRETS=(n8n-core-secrets n8n-db-secret n8n-redis-secret n8n-runner-token)
[ "$LICENSE_AVAILABLE" = "true" ] && EXPECTED_K8S_SECRETS+=(n8n-license-secret)
MISSING_K8S=()
for s in "${EXPECTED_K8S_SECRETS[@]}"; do
  if kubectl get secret "$s" -n "$NAMESPACE" >/dev/null 2>&1; then
    ok "Synced: $s"
  else
    MISSING_K8S+=("$s")
    warn "MISSING: $s"
  fi
done

if [ ${#MISSING_K8S[@]} -gt 0 ]; then
  fail "CSI mount succeeded but ${#MISSING_K8S[@]} K8s Secret(s) were not created.
       Check secretObjects mappings in azure/secret-provider-class.yaml —
       every secretName listed there should appear in the namespace."
fi

# CRITICAL: Do NOT delete the keeper pod. The Azure Key Vault CSI driver
# garbage-collects the synced K8s Secret objects as soon as the last pod
# mounting the SPC is removed. The n8n chart's pods reference these Secrets
# via secretKeyRef but do NOT mount the SPC themselves — so if we delete the
# keeper, all n8n-* Secrets vanish and the chart pods fail with
# "secret not found". The keeper Deployment stays alive for the life of the
# namespace (~16Mi RAM, 10m CPU) to keep the CSI driver holding the Secrets.
info "Keeping n8n-secret-sync Deployment alive (required by CSI driver lifecycle)"

# === Phase 9: Ingress controller + TLS secret ===============================
section "PHASE 9 / 13 — Ingress controller + TLS secret"

if [ -z "$N8N_DOMAIN" ]; then
  info "N8N_DOMAIN not set in .env — skipping ingress + TLS setup."
  info "n8n will be ClusterIP-only — reach it via: kubectl port-forward svc/<main> 5678:5678 -n n8n"
else
  ok "N8N_DOMAIN is set: $N8N_DOMAIN"

  # Install nginx ingress controller if not already present
  if kubectl get ns ingress-nginx >/dev/null 2>&1 && \
     kubectl get deploy -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    ok "nginx-ingress controller already installed"
  else
    info "Installing nginx-ingress controller (one-time)..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    # MSYS_NO_PATHCONV=1 prevents Git Bash on Windows from translating /paths.
    #
    # Note: We deliberately DO NOT pass the probe-path annotation via --set
    # here. helm --set on annotation keys with dots+slashes is unreliable on
    # Windows Git Bash (silently mangles the value). Instead, we apply it via
    # `kubectl annotate` AFTER install (with MSYS_NO_PATHCONV=1) — see the
    # block below this one.
    MSYS_NO_PATHCONV=1 helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --create-namespace \
      --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true" \
      --wait --timeout 5m \
      || fail "Failed to install nginx-ingress controller"
    ok "nginx-ingress controller installed"
  fi

  # Point the Azure SLB health probe at nginx-ingress's /healthz (always 200).
  # Without it, the probe defaults to "/" → non-200 → backend unhealthy → 502.
  # Applied via kubectl (helm --set on dotted/slashed annotations is unreliable
  # on Git Bash for Windows); MSYS_NO_PATHCONV stops /healthz being path-mangled.
  if kubectl get svc -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    CURRENT_PROBE_PATH=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path}' 2>/dev/null)
    if [ "$CURRENT_PROBE_PATH" != "/healthz" ]; then
      info "Patching nginx-ingress probe path → /healthz (was: '$CURRENT_PROBE_PATH')"
      # MSYS_NO_PATHCONV=1 prevents Git Bash on Windows from translating
      # /healthz into a Windows path like C:/Users/.../Git/healthz.
      MSYS_NO_PATHCONV=1 kubectl annotate svc -n ingress-nginx ingress-nginx-controller \
        service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path=/healthz \
        --overwrite >/dev/null
      ok "Probe path annotation set to /healthz (Azure SLB will re-probe in ~60-90s)"
    else
      ok "Probe path annotation already correct (/healthz)"
    fi
  fi

  # Wait for ingress controller external IP
  info "Waiting for ingress controller external IP..."
  INGRESS_IP=""
  for i in {1..30}; do
    INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [ -n "$INGRESS_IP" ] && break
    sleep 10
  done
  if [ -n "$INGRESS_IP" ]; then
    ok "Ingress controller external IP: $INGRESS_IP"
    echo ""
    echo -e "  ${YELLOW}${BOLD}>>> DNS ACTION (if not done yet) <<<${NC}"
    echo "  Point this A record:"
    echo "     $N8N_DOMAIN  →  $INGRESS_IP"
    echo ""
  else
    warn "Ingress IP not assigned yet — check with: kubectl get svc -n ingress-nginx -w"
  fi

  # Create K8s TLS secret from .pfx file (single source — same file used for App Gateway)
  if [ -z "${TLS_PFX_PATH:-}" ]; then
    fail "N8N_DOMAIN is set but TLS_PFX_PATH is empty in .env.
         Set it to the path of your .pfx file (e.g. ./certs/n8n.pfx)."
  fi

  # Resolve relative path against PROJECT_DIR
  case "$TLS_PFX_PATH" in
    /*) PFX_FILE="$TLS_PFX_PATH" ;;
    *)  PFX_FILE="$PROJECT_DIR/$TLS_PFX_PATH" ;;
  esac

  if [ ! -f "$PFX_FILE" ]; then
    fail "PFX file not found: $PFX_FILE
         Drop your .pfx file in $PROJECT_DIR/certs/ and re-run.
         To create one from .cer + .p7b + .key:
           cat fullchain.cer privkey.p7b > combined.pem
           openssl pkcs12 -export -out n8n.pfx -inkey your.key -in combined.pem -password pass:YOURPWD"
  fi

  # Extract cert + key from PFX into temporary PEM files (Kubernetes secret needs PEM)
  PFX_PWD="${TLS_PFX_PASSWORD:-}"
  TMP_CERT="$PROJECT_DIR/certs/.cert.pem.tmp"
  TMP_KEY="$PROJECT_DIR/certs/.key.pem.tmp"

  info "Extracting cert + key from $(basename "$PFX_FILE") ..."

  # Try modern PFX first; fall back to -legacy for RC2/3DES PFX (App Gateway compatible).
  # OpenSSL 3.x doesn't enable RC2-40-CBC by default — needs -legacy or -provider legacy.
  PFX_OPTS=""
  if ! openssl pkcs12 -in "$PFX_FILE" -nokeys -nodes -out "$TMP_CERT" -password "pass:$PFX_PWD" 2>/dev/null; then
    if openssl pkcs12 -legacy -in "$PFX_FILE" -nokeys -nodes -out "$TMP_CERT" -password "pass:$PFX_PWD" 2>/dev/null; then
      PFX_OPTS="-legacy"
      info "PFX uses legacy crypto (RC2/3DES) — using -legacy flag"
    else
      fail "Failed to extract cert from PFX. Possible causes:
           1. Wrong TLS_PFX_PASSWORD in .env
           2. PFX file corrupt
         Verify with:  openssl pkcs12 -info -legacy -in $PFX_FILE -password pass:\$TLS_PFX_PASSWORD -noout"
    fi
  fi

  # Extract private key with same options
  if ! openssl pkcs12 $PFX_OPTS -in "$PFX_FILE" -nocerts -nodes -out "$TMP_KEY" -password "pass:$PFX_PWD" 2>/dev/null; then
    rm -f "$TMP_CERT"
    fail "Failed to extract key from PFX. Wrong password?"
  fi

  # Strip any "Bag Attributes" headers openssl adds — keep only PEM blocks
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$TMP_CERT" > "$TMP_CERT.clean" && mv "$TMP_CERT.clean" "$TMP_CERT"
  awk '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/' "$TMP_KEY" > "$TMP_KEY.clean" && mv "$TMP_KEY.clean" "$TMP_KEY"

  # Validate cert + key match
  CERT_HASH=$(openssl x509 -noout -modulus -in "$TMP_CERT" 2>/dev/null | openssl md5)
  KEY_HASH=$(openssl rsa -noout -modulus -in "$TMP_KEY" 2>/dev/null | openssl md5)
  if [ "$CERT_HASH" != "$KEY_HASH" ]; then
    rm -f "$TMP_CERT" "$TMP_KEY"
    fail "Cert + key from PFX don't match (modulus mismatch). PFX may be corrupt."
  fi
  ok "PFX extracted and validated (cert + key match)"

  # Recreate the K8s TLS secret (idempotent — handles renewal too)
  kubectl delete secret "$N8N_TLS_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl create secret tls "$N8N_TLS_SECRET_NAME" \
    --cert="$TMP_CERT" \
    --key="$TMP_KEY" \
    -n "$NAMESPACE" \
    || fail "Failed to create TLS secret $N8N_TLS_SECRET_NAME"
  ok "K8s TLS secret '$N8N_TLS_SECRET_NAME' created in namespace $NAMESPACE"

  # Cleanup extracted PEMs (sensitive — only need them for `kubectl create`)
  rm -f "$TMP_CERT" "$TMP_KEY"
  ok "Temporary PEM files cleaned up (PFX is the only persistent cert file)"
fi

# === Phase 9b: Custom CA trust bundle =======================================
# Load the internal CA cert (path from .env CUSTOM_CA_CERT_PATH) into the
# 'n8n-ca-bundle' ConfigMap as key 'ca-bundle.pem'. n8n trusts it via
# NODE_EXTRA_CA_CERTS (see values-enterprise.yaml extraVolumes). Required so
# AI/LangChain nodes reach internal-CA HTTPS (Azure OpenAI APIM). Idempotent.
CA_CERT_REL="${CUSTOM_CA_CERT_PATH:-./certs/internal-ca.pem}"
case "$CA_CERT_REL" in
  /*) CA_BUNDLE_FILE="$CA_CERT_REL" ;;
  *)  CA_BUNDLE_FILE="$PROJECT_DIR/${CA_CERT_REL#./}" ;;
esac
if [ -f "$CA_BUNDLE_FILE" ]; then
  info "Creating/updating 'n8n-ca-bundle' ConfigMap from $(basename "$CA_BUNDLE_FILE") ..."
  kubectl create configmap n8n-ca-bundle \
    --from-file=ca-bundle.pem="$CA_BUNDLE_FILE" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - \
    || fail "ConfigMap apply failed in namespace $NAMESPACE"
  ok "CA bundle ConfigMap 'n8n-ca-bundle' applied in namespace $NAMESPACE"
else
  # No CA yet — create a placeholder so the pod volume mount never fails.
  # NODE_EXTRA_CA_CERTS pointing at a cert-less file is harmless (Node warns, ignores).
  # Set CUSTOM_CA_CERT_PATH in .env to your CA PEM and re-run to enable trust.
  warn "No CA cert at $CA_BUNDLE_FILE (CUSTOM_CA_CERT_PATH) — creating a PLACEHOLDER ConfigMap.
        Internal-CA HTTPS (e.g. Azure OpenAI via APIM) stays broken until you add the CA + redeploy."
  kubectl create configmap n8n-ca-bundle \
    --from-literal=ca-bundle.pem="# placeholder — set CUSTOM_CA_CERT_PATH in .env to your CA PEM and redeploy" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - \
    || fail "ConfigMap apply failed in namespace $NAMESPACE"
fi

# === Phase 9c: Task runner launcher config ==================================
# Create the 'n8n-task-runners' ConfigMap from azure/n8n-task-runners.json so the
# runner sidecars enforce the Code-node module allow-lists (JS builtins + locked
# Python). In EXTERNAL runner mode these rules are read ONLY from this JSON, not from
# container env vars. Chart mounts it at /etc/n8n-task-runners.json (main + worker).
RUNNER_CFG="$PROJECT_DIR/azure/n8n-task-runners.json"
if [ -f "$RUNNER_CFG" ]; then
  info "Creating/updating 'n8n-task-runners' ConfigMap from $(basename "$RUNNER_CFG") ..."
  kubectl create configmap n8n-task-runners \
    --from-file=n8n-task-runners.json="$RUNNER_CFG" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - \
    || fail "ConfigMap apply failed in namespace $NAMESPACE"
  ok "Task runner config ConfigMap 'n8n-task-runners' applied in namespace $NAMESPACE"
else
  fail "Runner config not found at $RUNNER_CFG — required because taskRunners.customConfig.enabled=true.
        Restore azure/n8n-task-runners.json (in the repo) or set customConfig.enabled=false in values."
fi

# === Phase 10: Bootstrap PostgreSQL =========================================
section "PHASE 10 / 13 — Bootstrap PostgreSQL (create DB + app user)"

# Uses Azure CLI (az) — already on the jumpbox. No Docker image pull needed.
# Idempotent: safe to re-run — skips existing DB/user, always syncs password.

# Extract server name from FQDN (e.g. "myserver.postgres.database.azure.com" → "myserver")
PG_SERVER_NAME=$(echo "$AZURE_POSTGRES_HOST" | cut -d. -f1)
info "PostgreSQL server: $PG_SERVER_NAME (RG: $RESOURCE_GROUP)"

# Read credentials from CSI-synced K8s secrets (created in Phase 7)
info "Reading DB credentials from K8s secrets..."
DB_ADMIN_PASS=$(kubectl get secret n8n-db-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
DB_APP_PASS=$(kubectl get secret n8n-db-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.app-password}' 2>/dev/null | base64 -d 2>/dev/null)

[ -n "$DB_ADMIN_PASS" ] || fail "Could not read admin password from n8n-db-secret (key: password). Check KV secret 'n8n-db-password'."
[ -n "$DB_APP_PASS" ]   || fail "Could not read app password from n8n-db-secret (key: app-password). Check KV secret 'n8n-db-app-password'."
ok "DB credentials read from K8s secrets"

# Escape single quotes in password for SQL
DB_APP_PASS_SQL="${DB_APP_PASS//\'/\'\'}"

# ── 8a. Create database via ARM API (no direct DB connectivity needed) ──
info "Creating database '$POSTGRES_DB_NAME' (via Azure ARM API)..."
if az postgres flexible-server db show \
     --server-name "$PG_SERVER_NAME" \
     --resource-group "$RESOURCE_GROUP" \
     --database-name "$POSTGRES_DB_NAME" >/dev/null 2>&1; then
  ok "Database '$POSTGRES_DB_NAME' already exists"
else
  if az postgres flexible-server db create \
       --server-name "$PG_SERVER_NAME" \
       --resource-group "$RESOURCE_GROUP" \
       --database-name "$POSTGRES_DB_NAME" >/dev/null 2>&1; then
    ok "Database '$POSTGRES_DB_NAME' created"
  else
    fail "Could not create database '$POSTGRES_DB_NAME'.
         Check: az permissions, server name ($PG_SERVER_NAME), resource group ($RESOURCE_GROUP)."
  fi
fi

# ── 8b. Create user + grants via az postgres execute ────────────────────
# Requires rdbms-connect extension (auto-installed) and network path to PG.
info "Installing Azure CLI rdbms-connect extension..."
az extension add --name rdbms-connect --yes 2>/dev/null || true

# Helper: run SQL via az postgres flexible-server execute
_run_sql() {
  local db="$1"
  local sql="$2"
  az postgres flexible-server execute \
    --name "$PG_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --admin-user "$POSTGRES_USERNAME" \
    --admin-password "$DB_ADMIN_PASS" \
    --database-name "$db" \
    --querytext "$sql" 2>&1
}

# Test connectivity first
info "Testing SQL connectivity to $PG_SERVER_NAME ..."
if _run_sql "postgres" "SELECT 1" >/dev/null 2>&1; then
  ok "SQL connectivity verified"

  # Create user (idempotent — ignore "already exists")
  info "Creating/updating user '$POSTGRES_APP_USER'..."
  _run_sql "postgres" "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$POSTGRES_APP_USER') THEN CREATE ROLE $POSTGRES_APP_USER LOGIN PASSWORD '$DB_APP_PASS_SQL'; ELSE ALTER ROLE $POSTGRES_APP_USER WITH PASSWORD '$DB_APP_PASS_SQL'; END IF; END \$\$;" >/dev/null 2>&1
  ok "User '$POSTGRES_APP_USER' ready (password synced from KeyVault)"

  # Grant privileges
  info "Granting privileges..."
  _run_sql "postgres" "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB_NAME TO $POSTGRES_APP_USER" >/dev/null 2>&1
  _run_sql "$POSTGRES_DB_NAME" "GRANT ALL ON SCHEMA public TO $POSTGRES_APP_USER; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $POSTGRES_APP_USER; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $POSTGRES_APP_USER; GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $POSTGRES_APP_USER; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $POSTGRES_APP_USER; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $POSTGRES_APP_USER; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO $POSTGRES_APP_USER" >/dev/null 2>&1
  ok "Privileges granted"

  # Verify app user connectivity
  info "Verifying '$POSTGRES_APP_USER' can connect..."
  if az postgres flexible-server execute \
       --name "$PG_SERVER_NAME" \
       --resource-group "$RESOURCE_GROUP" \
       --admin-user "$POSTGRES_APP_USER" \
       --admin-password "$DB_APP_PASS" \
       --database-name "$POSTGRES_DB_NAME" \
       --querytext "SELECT 1" >/dev/null 2>&1; then
    ok "Verified — '$POSTGRES_APP_USER' can connect to '$POSTGRES_DB_NAME'"
  else
    warn "App user verification failed — n8n pods will retry on startup."
    info "If auth keeps failing, check password in KV (n8n-db-app-password) matches PostgreSQL."
  fi

else
  # az execute can't reach PG (jumpbox has no network path to private endpoint)
  warn "Cannot reach PostgreSQL from this jumpbox via az CLI."
  warn "Database '$POSTGRES_DB_NAME' was created via ARM API (above)."
  echo ""
  echo -e "  ${YELLOW}${BOLD}>>> MANUAL STEP NEEDED <<<${NC}"
  echo "  The app user must be created via Azure Portal:"
  echo "    1. Portal → PostgreSQL Flexible Server → Connect"
  echo "    2. Run this SQL (replace <APP_PASSWORD> with KV secret n8n-db-app-password):"
  echo ""
  echo "       CREATE ROLE $POSTGRES_APP_USER LOGIN PASSWORD '<APP_PASSWORD>';"
  echo "       GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB_NAME TO $POSTGRES_APP_USER;"
  echo "       \\connect $POSTGRES_DB_NAME"
  echo "       GRANT ALL ON SCHEMA public TO $POSTGRES_APP_USER;"
  echo "       GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $POSTGRES_APP_USER;"
  echo "       GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $POSTGRES_APP_USER;"
  echo "       ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $POSTGRES_APP_USER;"
  echo "       ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $POSTGRES_APP_USER;"
  echo ""
  read -p "Done in Portal? Press ENTER to continue..." _
fi

ok "PostgreSQL bootstrap complete"

# === Phase 11: Fetch the official Helm chart (local copy) ================
section "PHASE 11 / 13 — Obtain the Helm chart (private ACR preferred, github.com fallback)"

# Always work from PROJECT_DIR
cd "$PROJECT_DIR" || fail "Cannot cd to $PROJECT_DIR"

# PREFERRED: pull the chart from the private ACR (imported server-side in Phase 3).
# helm pull --untar makes it a local dir, so lint/install downstream are unchanged.
if [ "$CHART_IN_ACR" = true ]; then
  info "Pulling Helm chart from private ACR: oci://$ACR_LOGIN_SERVER/helm/n8n:$CHART_VERSION_EXPECTED"
  # Authenticate helm to ACR WITHOUT Docker. Plain `az acr login` needs the Docker
  # CLI/daemon (absent on this jumpbox → it fails and helm pull 401s). Instead we use
  # `--expose-token` to get an ACR access token and feed it to `helm registry login`
  # via ACR's well-known token username (all-zeros GUID). Docker-free, jumpbox-friendly.
  ACR_TOKEN=$(az acr login -n "$ACR_NAME" "${ACR_SUB_ARGS[@]}" --expose-token --query accessToken -o tsv 2>/dev/null)
  if [ -n "$ACR_TOKEN" ]; then
    echo "$ACR_TOKEN" | helm registry login "$ACR_LOGIN_SERVER" \
        --username "00000000-0000-0000-0000-000000000000" --password-stdin >/dev/null 2>&1 \
      || warn "helm registry login to ACR failed — will fall back to github.com"
  else
    warn "Could not get an ACR token (az acr login --expose-token failed) — will fall back to github.com"
  fi
  ACR_CHART_DIR="$PROJECT_DIR/n8n-hosting-acr"
  rm -rf "$ACR_CHART_DIR"; mkdir -p "$ACR_CHART_DIR"
  if helm pull "oci://$ACR_LOGIN_SERVER/helm/n8n" --version "$CHART_VERSION_EXPECTED" --untar --untardir "$ACR_CHART_DIR" 2>&1 | tail -5 \
       && [ -f "$ACR_CHART_DIR/n8n/Chart.yaml" ]; then
    LOCAL_CHART_DIR="$ACR_CHART_DIR/n8n"
    CHART="$LOCAL_CHART_DIR"
    CHART_SOURCE="private ACR (oci://$ACR_LOGIN_SERVER/helm/n8n:$CHART_VERSION_EXPECTED)"
    ok "Chart pulled from ACR → $LOCAL_CHART_DIR"
  else
    warn "helm pull from ACR failed — falling back to fetching the chart from github.com."
    CHART_IN_ACR=false
    LOCAL_CHART_DIR="$PROJECT_DIR/n8n-hosting/charts/n8n"; CHART="$LOCAL_CHART_DIR"
  fi
fi

# If a previous (bad) fetch left an incomplete directory, nuke it
if [ -d "$PROJECT_DIR/n8n-hosting" ] && [ ! -f "$LOCAL_CHART_DIR/Chart.yaml" ]; then
  warn "Found incomplete n8n-hosting/ from a previous run. Removing..."
  rm -rf "$PROJECT_DIR/n8n-hosting"
fi

if [ -f "$LOCAL_CHART_DIR/Chart.yaml" ]; then
  ok "Chart already present at $LOCAL_CHART_DIR"
else
  info "Chart not found locally — fetching tag v${CHART_VERSION_EXPECTED} from github.com ..."

  # Pin to exact tag — never use main HEAD (reproducibility requirement)
  CHART_TAG="v${CHART_VERSION_EXPECTED}"
  N8N_HOSTING_ZIP="${N8N_HOSTING_ZIP_BASE}/${CHART_TAG}.zip"
  N8N_HOSTING_ZIP_CODELOAD="${N8N_HOSTING_ZIP_CODELOAD_BASE}/${CHART_TAG}"

  CHART_OBTAINED=false

  # Method 1: git clone with --branch <tag> — pinned to exact tag
  if ! $CHART_OBTAINED && command -v git >/dev/null 2>&1; then
    info "Method 1/3: git clone --depth 1 --branch ${CHART_TAG} $N8N_HOSTING_REPO"
    if git clone --depth 1 --branch "$CHART_TAG" "$N8N_HOSTING_REPO" n8n-hosting 2>&1 | tail -5; then
      if [ -f "$LOCAL_CHART_DIR/Chart.yaml" ]; then
        ok "Obtained via git clone @ ${CHART_TAG}"
        CHART_OBTAINED=true
      else
        warn "git clone succeeded but Chart.yaml missing — repo layout changed?"
        rm -rf n8n-hosting 2>/dev/null || true
      fi
    else
      warn "git clone failed (tag may not exist?). Trying ZIP download..."
      rm -rf n8n-hosting 2>/dev/null || true
    fi
  fi

  # Method 2: curl + unzip from github.com tag archive
  if ! $CHART_OBTAINED && command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    info "Method 2/3: curl -sL $N8N_HOSTING_ZIP"
    if curl -fsSL -o n8n-hosting.zip "$N8N_HOSTING_ZIP"; then
      unzip -qo n8n-hosting.zip && rm -f n8n-hosting.zip
      # Tag archives extract as n8n-hosting-<version> (no leading v)
      if [ -d "n8n-hosting-${CHART_VERSION_EXPECTED}" ]; then
        mv "n8n-hosting-${CHART_VERSION_EXPECTED}" n8n-hosting
      fi
      if [ -f "$LOCAL_CHART_DIR/Chart.yaml" ]; then
        ok "Obtained via curl + unzip (github.com) @ ${CHART_TAG}"
        CHART_OBTAINED=true
      else
        rm -rf n8n-hosting 2>/dev/null || true
      fi
    else
      warn "curl from github.com failed. Trying codeload.github.com..."
      rm -f n8n-hosting.zip 2>/dev/null || true
    fi
  fi

  # Method 3: curl + unzip from codeload.github.com (alternate CDN)
  if ! $CHART_OBTAINED && command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    info "Method 3/3: curl -sL $N8N_HOSTING_ZIP_CODELOAD"
    if curl -fsSL -o n8n-hosting.zip "$N8N_HOSTING_ZIP_CODELOAD"; then
      unzip -qo n8n-hosting.zip && rm -f n8n-hosting.zip
      if [ -d "n8n-hosting-${CHART_VERSION_EXPECTED}" ]; then
        mv "n8n-hosting-${CHART_VERSION_EXPECTED}" n8n-hosting
      fi
      if [ -f "$LOCAL_CHART_DIR/Chart.yaml" ]; then
        ok "Obtained via curl + unzip (codeload.github.com) @ ${CHART_TAG}"
        CHART_OBTAINED=true
      else
        rm -rf n8n-hosting 2>/dev/null || true
      fi
    else
      warn "codeload.github.com also failed."
      rm -f n8n-hosting.zip 2>/dev/null || true
    fi
  fi

  if ! $CHART_OBTAINED; then
    fail "Could not fetch chart tag ${CHART_TAG} from ANY of:
           - git clone --branch ${CHART_TAG} $N8N_HOSTING_REPO
           - curl $N8N_HOSTING_ZIP
           - curl $N8N_HOSTING_ZIP_CODELOAD
         Verify the tag exists at https://github.com/n8n-io/n8n-hosting/releases
         If you need a newer version, update N8N_CHART_VERSION in .env.

        Your firewall may block github.com entirely. Workaround:
          1. On a machine with internet, run:
               git clone https://github.com/n8n-io/n8n-hosting.git
          2. Transfer the n8n-hosting/ folder to:
               $PROJECT_DIR/n8n-hosting
          3. Re-run this script."
  fi
fi

# Final sanity check — chart MUST exist at this point
[ -f "$LOCAL_CHART_DIR/Chart.yaml" ] \
  || fail "Chart.yaml not found at $LOCAL_CHART_DIR. Something went wrong during fetch."
[ -d "$LOCAL_CHART_DIR/templates" ] \
  || fail "templates/ directory missing at $LOCAL_CHART_DIR. Corrupt download."

CHART_REAL_VERSION=$(grep '^version:' "$LOCAL_CHART_DIR/Chart.yaml" | awk '{print $2}')
CHART_APP_VERSION=$(grep '^appVersion:' "$LOCAL_CHART_DIR/Chart.yaml" | awk '{print $2}' | tr -d '"')

# The git TAG is the pin (deterministic). n8n-hosting's Chart.yaml `version:`
# inside a tag is offset by one release (tag v1.5.1 → Chart.yaml 1.5.0), so a
# tag-vs-Chart.yaml difference is expected — report it, never abort.
if [ "$CHART_REAL_VERSION" != "$CHART_VERSION_EXPECTED" ]; then
  info "Fetched git tag v$CHART_VERSION_EXPECTED → its Chart.yaml says version $CHART_REAL_VERSION"
  info "  (n8n-hosting's tag/Chart.yaml offset — expected, not an error)"
fi
ok "Chart pinned to tag v$CHART_VERSION_EXPECTED (Chart.yaml $CHART_REAL_VERSION, n8n app $CHART_APP_VERSION)"
ok "Chart path:    $LOCAL_CHART_DIR"

# === Phase 12: Helm install ============================================
section "PHASE 12 / 13 — Helm install n8n Enterprise"

# HARD GUARD: $CHART must be a local directory containing Chart.yaml.
# If it ever becomes an oci:// URL, we abort immediately so the user sees
# the root cause instead of another mysterious 403 from ghcr.io.
case "$CHART" in
  oci://*|http://*|https://*)
    fail "CHART is set to a remote URL ($CHART). This script MUST install from a local directory because the corporate firewall blocks the ghcr.io blob CDN. Check deploy.sh — CHART should equal \$LOCAL_CHART_DIR."
    ;;
esac
[ -f "$CHART/Chart.yaml" ] \
  || fail "CHART=$CHART does not contain Chart.yaml. Phase 8 should have fetched it — check the logs above."

info "Chart:      $CHART"
info "Source:     $CHART_SOURCE"
info "Version:    $CHART_REAL_VERSION (expected $CHART_VERSION_EXPECTED)"
info "AppVer:     $CHART_APP_VERSION"
info "Values:     $VALUES_FILE"
info "Release:    $RELEASE_NAME"
info "Namespace:  $NAMESPACE"
info "Image:      $N8N_IMAGE_REPOSITORY:$N8N_IMAGE_TAG"
info "Runners:    $RUNNERS_IMAGE_REPOSITORY:$RUNNERS_IMAGE_TAG"
echo ""

# Verify values file exists and is non-empty
[ -s "$VALUES_FILE" ] || fail "values-enterprise.yaml missing or empty at $VALUES_FILE"

# Defense-in-depth: pass image repo/tag via --set in addition to the values
# file. This guarantees the correct image is used even if the values file is
# stale (e.g. placeholders not substituted, a leftover :stable override, or a
# copy from an older V* folder). --set has higher precedence than -f values.
# LICENSE_AVAILABLE was set in Phase 4 based on KV state. Use it to drive
# Helm overrides (multiMain, license.enabled).

# Service type is always ClusterIP — AppGW + nginx-ingress handle external access.
# (No more LoadBalancer fallback — committed to ingress topology.)

HELM_SET_ARGS=(
  --set "image.repository=$N8N_IMAGE_REPOSITORY"
  --set "image.tag=$N8N_IMAGE_TAG"
  --set "image.pullPolicy=IfNotPresent"
  --set "taskRunners.image.repository=$RUNNERS_IMAGE_REPOSITORY"
  --set "taskRunners.image.tag=$RUNNERS_IMAGE_TAG"
  --set "taskRunners.image.pullPolicy=IfNotPresent"
  # NOTE: Database SSL is handled by:
  #  - values-enterprise.yaml database.ssl.* (chart's structured config), AND
  #  - extraEnv DB_POSTGRESDB_SSL_ENABLED=true (defense-in-depth env var)
  # No --set override needed — removing reduces schema-mismatch risk on chart upgrades.
  # Ingress — auto-toggled based on N8N_DOMAIN in .env
  --set "ingress.enabled=$INGRESS_ENABLED"
  # Webhook-processor ingress — routes /webhook + /webhook-waiting to the webhook pods
  # (main pods reject production webhooks). Tracks the main ingress (needs a hostname).
  --set "ingress.webhookProcessor.enabled=$INGRESS_ENABLED"
  # Service type — always ClusterIP (AppGW + nginx-ingress handle external access)
  --set "service.type=ClusterIP"
)

# License handling:
#  A) N8N_LICENSE_KEY in .env → inject into Helm chart for auto-activation
#  B) LICENSE_ACTIVATED=true (UI-activated) → trust user, multi-main on
#  C) Neither → disable multi-main + license to prevent deploy failure
if [ "$LICENSE_VIA_KEY" = "true" ]; then
  # Path A: pass the key directly to the chart so n8n auto-activates.
  # CRITICAL: Chart's _helpers.tpl FAILS the install if both `activationKey`
  # AND `existingSecret.name` are set (mutually exclusive). Must clear
  # existingSecret.name when using activationKey.
  HELM_SET_ARGS+=(
    --set-string "license.activationKey=$N8N_LICENSE_KEY"
    --set "license.existingSecret.name=null"
  )
  ok "Passing license activation key to Helm (auto-activates on first start)"
elif [ "$LICENSE_AVAILABLE" != "true" ]; then
  # Path C: no license at all — gracefully degrade
  HELM_SET_ARGS+=(
    --set "multiMain.enabled=false"
    --set "hpa.main.enabled=false"
    --set "license.enabled=false"
  )
  warn "No license configured → deploying single-main mode (no HA)"
fi
# Path B (UI-activated): no override needed — values file's multiMain.enabled=true stands

# Lint the chart against our values BEFORE installing — catches schema errors
# and missing required fields in seconds instead of waiting for a timeout.
info "Linting chart with values-enterprise.yaml (and image overrides)..."
if ! helm lint "$CHART" --values "$VALUES_FILE" --namespace "$NAMESPACE" "${HELM_SET_ARGS[@]}" 2>&1 | tail -30; then
  fail "helm lint failed. Fix values-enterprise.yaml errors above before installing."
fi
ok "helm lint passed"
echo ""

# Run the install — stream output so user sees progress (no quiet/suppression)
info "Running: helm upgrade --install $RELEASE_NAME $CHART (timeout 15m)"
info "  +image.repository=$N8N_IMAGE_REPOSITORY"
info "  +image.tag=$N8N_IMAGE_TAG"
info "  +taskRunners.image.repository=$RUNNERS_IMAGE_REPOSITORY"
info "  +taskRunners.image.tag=$RUNNERS_IMAGE_TAG"
echo ""
# Script runs under `set -uo pipefail` (no -e), so this block captures RC
# without being aborted by pipefail on helm's progress output.
helm upgrade --install "$RELEASE_NAME" "$CHART" \
     --namespace "$NAMESPACE" \
     --values "$VALUES_FILE" \
     "${HELM_SET_ARGS[@]}" \
     --timeout 15m \
     --wait
HELM_RC=$?

if [ $HELM_RC -ne 0 ]; then
  # --wait non-zero is often just a timeout on the last main pod while n8n is
  # already serving. Only hard-fail if the release isn't deployed OR no main
  # pod is Ready; otherwise report degraded-HA and continue.
  echo ""
  warn "helm --wait returned non-zero (exit $HELM_RC). Checking ACTUAL health..."

  REL_STATUS=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
                | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  MAIN_READY=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=main \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c "True")
  MAIN_TOTAL=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=main --no-headers 2>/dev/null | wc -l)
  MAIN_READY=${MAIN_READY:-0}; MAIN_TOTAL=${MAIN_TOTAL:-0}

  if [ "$REL_STATUS" = "deployed" ] && [ "$MAIN_READY" -ge 1 ]; then
    ok "n8n is DEPLOYED and SERVING — $MAIN_READY/$MAIN_TOTAL main pods Ready"
    if [ "$MAIN_READY" -lt "$MAIN_TOTAL" ]; then
      echo ""
      warn "DEGRADED HA: $((MAIN_TOTAL - MAIN_READY)) main pod(s) not Ready (n8n still works)."
      warn "Almost always resource pressure (CPU/memory) on the node pool. Check:"
      warn "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=main -o wide"
      warn "  kubectl describe pod -n $NAMESPACE <not-ready-pod> | tail -30"
      warn "If you see 'Insufficient cpu/memory' → either:"
      warn "  (a) lower multiMain.replicas to 2 in values-enterprise.yaml (still HA), OR"
      warn "  (b) add a node to the AKS pool."
      echo ""
    fi
    # Continue — do NOT abort. n8n is up.
  else
    # Genuinely failed — show full diagnostics and stop.
    echo ""
    warn "Helm install FAILED (release status='$REL_STATUS', main ready=$MAIN_READY/$MAIN_TOTAL). Diagnostics:"
    echo ""
    echo "--- helm status ---"
    helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>&1 | tail -30 || true
    echo ""
    echo "--- recent events (last 30) ---"
    kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>&1 | tail -30 || true
    echo ""
    echo "--- pods ---"
    kubectl get pods -n "$NAMESPACE" 2>&1 || true
    echo ""
    echo "--- pod describes ---"
    for p in $(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null); do
      echo ">>> $p"
      kubectl describe "$p" -n "$NAMESPACE" 2>&1 | tail -40
      echo ""
    done
    echo ""
    fail "Helm install did not complete. Likely causes:
       1. Image pull blocked — check image.repository/ACR.
       2. CSI secret not mounted — kubectl get secrets -n $NAMESPACE
       3. Values schema mismatch — re-read values-enterprise.yaml."
  fi
fi

# Don't trust helm's own exit code alone — double-check the release actually
# exists in a good state before declaring success.
REAL_STATUS=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null \
              | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ "$REAL_STATUS" != "deployed" ]; then
  fail "Helm reported success but release status is '$REAL_STATUS' (expected 'deployed'). Run: helm status $RELEASE_NAME -n $NAMESPACE"
fi
ok "Helm release deployed (status=$REAL_STATUS)"

# === Phase 13: Validate =================================================
section "PHASE 13 / 13 — Validate"

echo ""
echo "--- Pods ---"
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "--- Services ---"
kubectl get svc -n "$NAMESPACE"

echo ""
echo "--- HPA ---"
kubectl get hpa -n "$NAMESPACE"

echo ""
echo "--- PDB ---"
kubectl get pdb -n "$NAMESPACE" 2>/dev/null || true

# Run the full validation suite (folded in — same checks as standalone validate.sh).
# Runs under set -uo pipefail (no -e) so a non-zero validation result is reported
# but does not abort the success summary below.
if [ -f "$SCRIPT_DIR/validate.sh" ]; then
  echo ""
  info "Running post-deploy validation (scripts/validate.sh)..."
  bash "$SCRIPT_DIR/validate.sh" || warn "Some validation checks did not pass — review output above."
fi

echo ""
section "DEPLOYMENT COMPLETE"

if [ -n "$N8N_DOMAIN" ]; then
  # Domain mode: ingress controller is the public entry point
  INGRESS_LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  echo ""
  echo -e "  ${GREEN}${BOLD}n8n is accessible at: ${N8N_PROTOCOL}://${N8N_DOMAIN}/${NC}"
  echo ""
  if [ -n "$INGRESS_LB_IP" ]; then
    echo "  Ingress controller external IP: $INGRESS_LB_IP"
    echo "  → Verify DNS A record: $N8N_DOMAIN  →  $INGRESS_LB_IP"
  fi
  echo ""
  echo "  Next steps:"
  echo "    1. Open ${N8N_PROTOCOL}://${N8N_DOMAIN}/ in your browser"
  echo "    2. Complete the Owner setup wizard (creates the break-glass account)"
  echo "    3. Enable 'Allow Manual Login' on the Owner: Settings → Users → ⋯"
  echo "    4. Activate your Enterprise license: Settings → Usage and plan"
  echo "    5. (Later) Activate SAML — see docs/AUTH-SAML-RUNBOOK.md"
else
  # No domain: service is ClusterIP, no external IP exists.
  # Access via kubectl port-forward only (developer/testing path).
  echo ""
  echo -e "  ${YELLOW}${BOLD}N8N_DOMAIN is not set — no external entry point.${NC}"
  echo ""
  echo "  Access n8n locally via port-forward:"
  echo "    kubectl port-forward -n $NAMESPACE svc/n8n-enterprise-main 5678:5678"
  echo "    Then open http://localhost:5678 in your browser"
  echo ""
  echo "  For production access:"
  echo "    1. Set N8N_DOMAIN in .env (e.g., n8n.example.com)"
  echo "    2. Drop your TLS .pfx in certs/"
  echo "    3. Re-run: ./scripts/deploy.sh"
fi

echo ""
echo -e "${GREEN}${BOLD}=== deploy.sh finished ===${NC}"
echo ""
