#!/bin/bash
# RunAI deployment script (run on the Brev instance *after* setting RUNAI_JFROG_TOKEN)
set -euo pipefail

RUNAI_DOMAIN="${RUNAI_DOMAIN:-runai.local}"
RUNAI_VERSION="${RUNAI_VERSION:-2.24.37}"
RUNAI_CERT_DIR="${RUNAI_CERT_DIR:-/tmp/runai-certs}"

RUNAI_CONTROL_PLANE_DOMAIN="${RUNAI_CONTROL_PLANE_DOMAIN:-$RUNAI_DOMAIN}"
RUNAI_CLUSTER_NAME="${RUNAI_CLUSTER_NAME:-brev-cluster}"
RUNAI_CLUSTER_VERSION="${RUNAI_CLUSTER_VERSION:-$RUNAI_VERSION}"

RUNAI_USERNAME="${RUNAI_USERNAME:-test@run.ai}"
RUNAI_PASSWORD="${RUNAI_PASSWORD:-Abcd!234}"

RUNAI_BACKEND_NAMESPACE="${RUNAI_BACKEND_NAMESPACE:-runai-backend}"
RUNAI_CLUSTER_NAMESPACE="${RUNAI_CLUSTER_NAMESPACE:-runai}"

RUNAI_REGISTRY_SERVER="${RUNAI_REGISTRY_SERVER:-runai.jfrog.io}"
RUNAI_REGISTRY_USERNAME="${RUNAI_REGISTRY_USERNAME:-self-hosted-image-puller-prod}"
RUNAI_REGISTRY_EMAIL="${RUNAI_REGISTRY_EMAIL:-support@run.ai}"
RUNAI_REGISTRY_SECRET_NAME="${RUNAI_REGISTRY_SECRET_NAME:-runai-reg-creds}"

# Set to 1 to force curl -k (if you did not install the CA on the instance)
RUNAI_CURL_INSECURE="${RUNAI_CURL_INSECURE:-0}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "[$(date +'%H:%M:%S')] WARN: $*" >&2; }
die() { echo "[$(date +'%H:%M:%S')] ERROR: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

k() {
  if have microk8s; then
    microk8s kubectl "$@"
  else
    kubectl "$@"
  fi
}

curl_flags=()
if [[ "${RUNAI_CURL_INSECURE}" == "1" ]]; then
  curl_flags+=("--insecure")
fi

ensure_deps() {
  have curl || die "curl is required"
  have helm || die "helm is required (run ./deploy_runai_prereqs.sh first)"

  if ! have jq; then
    if have apt-get; then
      log "Installing jq..."
      sudo apt-get update -y >/dev/null
      sudo apt-get install -y jq >/dev/null
    else
      die "jq is required (install jq or use an image that includes it)"
    fi
  fi
}

ensure_token() {
  if [[ -z "${RUNAI_JFROG_TOKEN:-}" ]]; then
    die "RUNAI_JFROG_TOKEN is not set. Export it first, then re-run this script."
  fi
}

ensure_namespaces() {
  k create ns "${RUNAI_BACKEND_NAMESPACE}" >/dev/null 2>&1 || true
  k create ns "${RUNAI_CLUSTER_NAMESPACE}" >/dev/null 2>&1 || true
}

create_registry_secret() {
  log "Creating registry secret (${RUNAI_REGISTRY_SECRET_NAME})..."
  k delete secret "${RUNAI_REGISTRY_SECRET_NAME}" -n "${RUNAI_BACKEND_NAMESPACE}" >/dev/null 2>&1 || true

  k create secret docker-registry "${RUNAI_REGISTRY_SECRET_NAME}" -n "${RUNAI_BACKEND_NAMESPACE}" \
    --docker-server="${RUNAI_REGISTRY_SERVER}" \
    --docker-username="${RUNAI_REGISTRY_USERNAME}" \
    --docker-password="${RUNAI_JFROG_TOKEN}" \
    --docker-email="${RUNAI_REGISTRY_EMAIL}"
}

install_control_plane() {
  local ca_path="${RUNAI_CERT_DIR}/ca.crt"
  [[ -f "${ca_path}" ]] || die "CA cert not found at ${ca_path}. Did you run ./deploy_runai_prereqs.sh?"

  log "Ensuring RunAI helm repo is available..."
  helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  log "Installing RunAI control plane (version ${RUNAI_VERSION})..."
  helm upgrade -i runai-backend runai-backend/control-plane -n "${RUNAI_BACKEND_NAMESPACE}" \
    --version "${RUNAI_VERSION}" \
    --set "global.domain=${RUNAI_DOMAIN}" \
    --set "global.customCA.enabled=true" \
    --set-file "global.customCA.caPEM=${ca_path}" \
    --set "global.imagePullSecrets[0].name=${RUNAI_REGISTRY_SECRET_NAME}" \
    --wait --timeout=25m

  log "Control plane install complete."
}

obtain_access_token() {
  # Prints access token to stdout
  local domain="${RUNAI_CONTROL_PLANE_DOMAIN}"

  log "Obtaining authentication token..."
  curl -fsS "${curl_flags[@]}" \
    --location \
    --request POST "https://${domain}/auth/realms/runai/protocol/openid-connect/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'client_id=runai' \
    --data-urlencode "username=${RUNAI_USERNAME}" \
    --data-urlencode "password=${RUNAI_PASSWORD}" \
    --data-urlencode 'scope=openid' \
    --data-urlencode 'response_type=id_token' \
    | jq -r .access_token
}

create_cluster() {
  # Prints UUID to stdout
  local token="$1"
  local domain="${RUNAI_CONTROL_PLANE_DOMAIN}"

  log "Creating cluster in RunAI Control Plane..."
  local response
  response="$(curl -fsS "${curl_flags[@]}" \
    -X POST "https://${domain}/api/v1/clusters" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "accept: application/json" \
    -d "{
      \"name\": \"${RUNAI_CLUSTER_NAME}\",
      \"version\": \"${RUNAI_CLUSTER_VERSION}\",
      \"domain\": \"${domain}\"
    }")"

  echo "${response}" | jq -r .uuid
}

get_installation_string() {
  # Prints installationStr to stdout
  local token="$1"
  local uuid="$2"
  local domain="${RUNAI_CONTROL_PLANE_DOMAIN}"

  log "Retrieving cluster installation string..."
  curl -fsS "${curl_flags[@]}" \
    "https://${domain}/api/v1/clusters/${uuid}/cluster-install-info?version=${RUNAI_CLUSTER_VERSION}" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    | jq -r .installationStr
}

install_cluster_from_string() {
  local installationStr="$1"
  local ca_path="${RUNAI_CERT_DIR}/ca.crt"
  [[ -f "${ca_path}" ]] || die "CA cert not found at ${ca_path}"

  log "Installing cluster into Kubernetes..."

  # Convert the multi-line UI string into a single helm command.
  local evalStr
  evalStr="$(echo "${installationStr}" \
    | sed '1,2d' \
    | sed ':a;N;$!ba;s/\n/ /g' \
    | sed 's/upgrade -i/install/g' \
    | tr '\\' ' ')"

  if [[ ! "${evalStr}" =~ ^helm[[:space:]] ]]; then
    die "Invalid installation command format (expected helm command). Got: ${evalStr}"
  fi

  # Ensure we include the custom CA flag for the cluster chart.
  if [[ "${evalStr}" != *"customCA.caPEM"* ]]; then
    evalStr="${evalStr} --set-file customCA.caPEM=${ca_path}"
  fi

  log "Executing: ${evalStr}"
  eval "${evalStr}"
}

main() {
  log "=== RunAI deploy (control plane + add cluster) ==="
  log "Domain: ${RUNAI_DOMAIN}"
  log "Control-plane domain: ${RUNAI_CONTROL_PLANE_DOMAIN}"
  log "Cluster: ${RUNAI_CLUSTER_NAME} (version ${RUNAI_CLUSTER_VERSION})"

  ensure_deps
  ensure_token
  ensure_namespaces

  create_registry_secret
  install_control_plane

  local token
  token="$(obtain_access_token)"
  [[ -n "${token}" && "${token}" != "null" ]] || die "Failed to obtain access token (check RUNAI_USERNAME/RUNAI_PASSWORD and control plane readiness)."

  local uuid
  uuid="$(create_cluster "${token}")"
  [[ -n "${uuid}" && "${uuid}" != "null" ]] || die "Failed to create cluster (uuid missing)."

  local installationStr
  installationStr="$(get_installation_string "${token}" "${uuid}")"
  [[ -n "${installationStr}" && "${installationStr}" != "null" ]] || die "Failed to retrieve installation string."

  install_cluster_from_string "${installationStr}"

  log "Done."
  log "Open the UI: https://${RUNAI_DOMAIN}"
}

main "$@"