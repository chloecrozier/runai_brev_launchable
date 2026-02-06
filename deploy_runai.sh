#!/bin/bash
# Installs RunAI control plane + cluster. Run after setting RUNAI_JFROG_TOKEN.
set -euo pipefail

RUNAI_DOMAIN="${RUNAI_DOMAIN:-runai.brev.cloud}"
RUNAI_VERSION="${RUNAI_VERSION:-2.24.37}"
RUNAI_CERT_DIR="${RUNAI_CERT_DIR:-/tmp/runai-certs}"
RUNAI_CLUSTER_NAME="${RUNAI_CLUSTER_NAME:-brev-cluster}"
RUNAI_USERNAME="${RUNAI_USERNAME:-test@run.ai}"
RUNAI_PASSWORD="${RUNAI_PASSWORD:-Abcd!234}"
RUNAI_CURL_INSECURE="${RUNAI_CURL_INSECURE:-0}"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
die()  { echo "[$(date +'%H:%M:%S')] ERROR: $*" >&2; exit 1; }

curl_flags=(); [[ "${RUNAI_CURL_INSECURE}" == "1" ]] && curl_flags+=("--insecure")

# --- Pre-flight ---
command -v helm >/dev/null || die "helm not found. Did setup_prereqs.sh run?"
command -v jq >/dev/null  || { sudo apt-get update -y >/dev/null && sudo apt-get install -y jq >/dev/null; }
[[ -n "${RUNAI_JFROG_TOKEN:-}" ]] || die "RUNAI_JFROG_TOKEN is not set. Run:  export RUNAI_JFROG_TOKEN=\"your-token\""
[[ -f "${RUNAI_CERT_DIR}/ca.crt" ]] || die "CA cert not found at ${RUNAI_CERT_DIR}/ca.crt — setup_prereqs.sh may not have run."

log "=== Deploying RunAI (${RUNAI_VERSION}) ==="

# --- Registry secret ---
log "Creating registry secret..."
kubectl delete secret runai-reg-creds -n runai-backend 2>/dev/null || true
kubectl create secret docker-registry runai-reg-creds -n runai-backend \
  --docker-server=runai.jfrog.io \
  --docker-username=self-hosted-image-puller-prod \
  --docker-password="${RUNAI_JFROG_TOKEN}" \
  --docker-email=support@run.ai

# --- Control plane ---
log "Installing control plane..."
helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
helm repo update >/dev/null 2>&1
helm upgrade -i runai-backend runai-backend/control-plane -n runai-backend \
  --version "${RUNAI_VERSION}" \
  --set "global.domain=${RUNAI_DOMAIN}" \
  --set "global.customCA.enabled=true" \
  --set-file "global.customCA.caPEM=${RUNAI_CERT_DIR}/ca.crt" \
  --set "global.imagePullSecrets[0].name=runai-reg-creds" \
  --wait --timeout=25m

# --- Ensure host can resolve the domain ---
grep -q "${RUNAI_DOMAIN}" /etc/hosts 2>/dev/null || echo "127.0.0.1 ${RUNAI_DOMAIN}" | sudo tee -a /etc/hosts >/dev/null

# --- Auth token ---
log "Waiting for control plane to be ready..."
sleep 15

log "Obtaining auth token..."
token=$(curl -fsS "${curl_flags[@]}" --location \
  --request POST "https://${RUNAI_DOMAIN}/auth/realms/runai/protocol/openid-connect/token" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'client_id=runai' \
  --data-urlencode "username=${RUNAI_USERNAME}" \
  --data-urlencode "password=${RUNAI_PASSWORD}" \
  --data-urlencode 'scope=openid' \
  --data-urlencode 'response_type=id_token' | jq -r .access_token)
[[ -n "${token}" && "${token}" != "null" ]] || die "Failed to get auth token."

# --- Create cluster ---
log "Creating cluster '${RUNAI_CLUSTER_NAME}'..."
response=$(curl -fsS "${curl_flags[@]}" \
  -X POST "https://${RUNAI_DOMAIN}/api/v1/clusters" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -H "accept: application/json" \
  -d "{\"name\":\"${RUNAI_CLUSTER_NAME}\",\"version\":\"${RUNAI_VERSION}\",\"domain\":\"${RUNAI_DOMAIN}\"}")
uuid=$(echo "${response}" | jq -r .uuid)
[[ -n "${uuid}" && "${uuid}" != "null" ]] || die "Failed to create cluster."
log "Cluster UUID: ${uuid}"

# --- Install cluster ---
log "Retrieving cluster install command..."
installationStr=$(curl -fsS "${curl_flags[@]}" \
  "https://${RUNAI_DOMAIN}/api/v1/clusters/${uuid}/cluster-install-info?version=${RUNAI_VERSION}" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${token}" \
  -H 'Content-Type: application/json' | jq -r .installationStr)
[[ -n "${installationStr}" && "${installationStr}" != "null" ]] || die "Failed to get install string."

evalStr=$(echo "${installationStr}" | sed '1,2d' | sed ':a;N;$!ba;s/\n/ /g' | sed 's/upgrade -i/install/g' | tr '\\' ' ')
[[ "${evalStr}" =~ ^helm[[:space:]] ]] || die "Invalid install command: ${evalStr}"
[[ "${evalStr}" == *"customCA.caPEM"* ]] || evalStr="${evalStr} --set-file customCA.caPEM=${RUNAI_CERT_DIR}/ca.crt"

log "Installing cluster..."
eval "${evalStr}"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP")
echo ""
echo "Done! UI: https://${RUNAI_DOMAIN}  (login: ${RUNAI_USERNAME} / ${RUNAI_PASSWORD})"
echo ""
echo "Run this on your LOCAL machine to access the UI:"
echo ""
echo "  sudo bash -c 'echo \"${PUBLIC_IP} ${RUNAI_DOMAIN}\" >> /etc/hosts'"
