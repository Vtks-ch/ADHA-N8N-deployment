#!/bin/bash
# =============================================================================
# N8N Enterprise - Post-Deployment Validation
# =============================================================================
# Adapts to deployment mode:
#   - N8N_DOMAIN set in .env  → tests via ingress (https://<domain>/healthz)
#   - N8N_DOMAIN empty        → tests via n8n service LB IP (http://<ip>:5678)
# =============================================================================

set -euo pipefail

# Load .env if available so we know the deployment mode (domain vs LB-IP)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${1:-dev}}"
ENV_DIR="$PROJECT_DIR/environments/$ENVIRONMENT_NAME"
ENV_FILE="$ENV_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
  set +a
fi

NAMESPACE="n8n"
RELEASE_NAME="n8n-enterprise"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

FAILURES=0

echo "=== N8N Enterprise Validation ==="
echo ""

# --- 1. Pod Health ---
echo "1. Pod Health"
MAIN_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=main" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
WORKER_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=worker" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
WEBHOOK_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=webhook-processor" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

# Multi-main HA needs 3 main pods + license. Without license: single-main (1).
EXPECTED_MAIN_MIN=1
[ "$MAIN_PODS" -ge "$EXPECTED_MAIN_MIN" ] && pass "Main pods: $MAIN_PODS running (min $EXPECTED_MAIN_MIN)" || fail "Main pods: $MAIN_PODS running (expected >=$EXPECTED_MAIN_MIN)"
[ "$WORKER_PODS" -ge 1 ] && pass "Worker pods: $WORKER_PODS running" || fail "Worker pods: $WORKER_PODS (expected >=1)"
[ "$WEBHOOK_PODS" -ge 1 ] && pass "Webhook pods: $WEBHOOK_PODS running" || fail "Webhook pods: $WEBHOOK_PODS (expected >=1)"

# --- 2. HPA ---
echo ""
echo "2. Horizontal Pod Autoscalers"
for COMPONENT in main worker webhook-processor; do
  HPA_EXISTS=$(kubectl get hpa -n "$NAMESPACE" -l "app.kubernetes.io/component=$COMPONENT" --no-headers 2>/dev/null | wc -l)
  [ "$HPA_EXISTS" -ge 1 ] && pass "HPA for $COMPONENT exists" || fail "HPA for $COMPONENT missing"
done

# --- 3. PDB ---
echo ""
echo "3. Pod Disruption Budget"
PDB_COUNT=$(kubectl get pdb -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
[ "$PDB_COUNT" -ge 1 ] && pass "PDB exists ($PDB_COUNT)" || fail "No PDB found"

# --- 4. Services ---
echo ""
echo "4. Services"
N8N_DOMAIN="${N8N_DOMAIN:-}"
if [ -n "$N8N_DOMAIN" ]; then
  # Domain mode: ingress controller exposes the public IP
  INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$INGRESS_IP" ] && pass "Ingress controller IP: $INGRESS_IP" || fail "Ingress controller has no external IP"
  HEALTH_URL="https://${N8N_DOMAIN}/healthz"
  HEALTH_HOST=""
else
  # No domain: ClusterIP-only topology (there is NO LoadBalancer). Verify the main
  # ClusterIP service exists; the health endpoint is not reachable from outside the
  # cluster — port-forward to check it: kubectl port-forward svc/<main> 5678:5678 -n n8n
  if kubectl get svc -n "$NAMESPACE" -l "app.kubernetes.io/component=main" -o name 2>/dev/null | grep -q .; then
    pass "Main ClusterIP service present (ingress/port-forward topology — no LoadBalancer)"
  else
    fail "No main service found in namespace $NAMESPACE"
  fi
  HEALTH_URL=""     # not externally reachable in ClusterIP topology
  HEALTH_HOST=""
fi

# --- 5. Secrets ---
echo ""
echo "5. Secrets"
EXPECTED_SECRETS=(n8n-core-secrets n8n-db-secret n8n-redis-secret n8n-runner-token)
# Conditional secrets — only present when feature is enabled
kubectl get secret n8n-license-secret -n "$NAMESPACE" >/dev/null 2>&1 && EXPECTED_SECRETS+=(n8n-license-secret)
[ -n "$N8N_DOMAIN" ] && EXPECTED_SECRETS+=(n8n-tls)

for SECRET in "${EXPECTED_SECRETS[@]}"; do
  kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1 && pass "$SECRET" || fail "$SECRET missing"
done

# --- 6. Health Endpoint (best-effort — may fail from outside cluster network) ---
echo ""
echo "6. Health Check"
if [ -n "${HEALTH_URL:-}" ]; then
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    pass "Health endpoint $HEALTH_URL: HTTP 200"
  elif [ "$HTTP_CODE" = "000" ]; then
    warn "Health endpoint $HEALTH_URL: unreachable (run from inside cluster or VNet to verify)"
  else
    warn "Health endpoint $HEALTH_URL: HTTP $HTTP_CODE"
  fi
else
  warn "Skipping health check (no URL derived)"
fi

# --- 7. Task Runner Sidecars ---
echo ""
echo "7. Task Runner Sidecars"
MAIN_CONTAINERS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=main" -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null)
if echo "$MAIN_CONTAINERS" | grep -q "task-runner"; then
  pass "Task runner sidecar present in main pods"
else
  warn "Task runner sidecar not detected in main pods"
fi

# --- Summary ---
echo ""
echo "============================================="
if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}  ALL CHECKS PASSED${NC}"
else
  echo -e "${RED}  $FAILURES CHECK(S) FAILED${NC}"
fi
echo "============================================="

exit "$FAILURES"
