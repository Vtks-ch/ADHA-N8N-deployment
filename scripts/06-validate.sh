#!/usr/bin/env bash
set -euo pipefail
NS=n8n
echo "=== AKS ==="
kubectl get nodes
echo "=== n8n workloads ==="
kubectl get deploy,pods,svc,hpa,pdb,networkpolicy -n "$NS" -o wide
echo "=== Helm ==="
helm status n8n-enterprise -n "$NS"
echo "=== CSI / synced secrets ==="
kubectl get secretproviderclass -n "$NS"
kubectl get secret n8n-core-secrets n8n-db-secret n8n-redis-secret n8n-runner-token -n "$NS"
echo "=== Ingress ==="
kubectl get ingress -n "$NS"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo "=== DNS/TLS ==="
kubectl describe ingress -n "$NS" || true
echo "Validation commands completed. Continue with application login, workflow, queue, webhook, blob, SSO and monitoring tests."
