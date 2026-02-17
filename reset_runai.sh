#!/bin/bash
# Tears down RunAI cluster + control plane so deploy_runai.sh can be re-run cleanly.
set -euo pipefail

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# --- Uninstall cluster agent ---
log "Uninstalling RunAI cluster agent..."
helm uninstall runai-cluster -n runai --wait 2>/dev/null || log "runai-cluster release not found, skipping."

# --- Clean up leftover cluster-scoped RBAC ---
# helm uninstall doesn't remove cluster-scoped resources that lack Helm ownership labels.
# If these linger, the next install fails with "invalid ownership metadata".
log "Cleaning up leftover RunAI cluster RBAC..."
kubectl get clusterrole -o name 2>/dev/null | grep -i runai | while read -r cr; do
  if ! kubectl get "$cr" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q Helm; then
    log "  Deleting orphaned $cr"
    kubectl delete "$cr" 2>/dev/null || true
  fi
done
kubectl get clusterrolebinding -o name 2>/dev/null | grep -i runai | while read -r crb; do
  if ! kubectl get "$crb" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q Helm; then
    log "  Deleting orphaned $crb"
    kubectl delete "$crb" 2>/dev/null || true
  fi
done

# --- Uninstall control plane ---
log "Uninstalling RunAI control plane..."
helm uninstall runai-backend -n runai-backend --wait 2>/dev/null || log "runai-backend release not found, skipping."

# --- Clean up secrets that deploy_runai.sh recreates ---
kubectl delete secret runai-reg-creds -n runai-backend 2>/dev/null || true

log "Reset complete. You can now re-run deploy_runai.sh."