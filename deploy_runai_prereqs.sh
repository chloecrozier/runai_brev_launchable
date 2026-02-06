#!/bin/bash
# RunAI prerequisites installer (run on the Brev instance)
set -euo pipefail

DOMAIN="${RUNAI_DOMAIN:-runai.local}"
VERSION="${RUNAI_VERSION:-2.24.37}"
CERT_DIR="${RUNAI_CERT_DIR:-/tmp/runai-certs}"
PUBLIC_IP="$(curl -fsS ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP")"

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

ensure_kubeconfig() {
  if have kubectl && kubectl version --client >/dev/null 2>&1; then
    # If kubectl already works against the cluster, leave it alone.
    if kubectl get nodes >/dev/null 2>&1; then
      return 0
    fi
  fi

  if have microk8s; then
    mkdir -p "${HOME}/.kube"
    microk8s config > "${HOME}/.kube/config"
    export KUBECONFIG="${HOME}/.kube/config"
  fi
}

fix_containerd() {
  # Fix MicroK8s containerd configs
  sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /var/snap/microk8s/current/args/containerd*.toml 2>/dev/null || true

  # Fix system containerd config (can conflict with MicroK8s)
  if [ -f /etc/containerd/config.toml ]; then
    sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /etc/containerd/config.toml 2>/dev/null || true
    if grep -q 'disabled_plugins = \["cri"\]' /etc/containerd/config.toml 2>/dev/null; then
      echo "version = 2" | sudo tee /etc/containerd/config.toml >/dev/null
    fi
  fi
}

ensure_microk8s_running() {
  if ! have microk8s; then
    die "microk8s not found. This script expects MicroK8s on the Brev image."
  fi

  fix_containerd

  if ! microk8s status 2>/dev/null | grep -q "is running"; then
    log "Starting MicroK8s..."
    if ! microk8s start 2>/dev/null; then
      warn "MicroK8s start failed; retrying after containerd fix..."
      fix_containerd
      microk8s start
    fi
    sleep 10
  fi

  ensure_kubeconfig

  log "Waiting for Kubernetes node readiness..."
  for i in {1..30}; do
    if k get nodes 2>/dev/null | grep -q " Ready"; then
      log "Node is Ready."
      break
    fi
    log "Waiting... ($i/30)"
    sleep 5
  done
  k wait --for=condition=ready node --all --timeout=180s 2>/dev/null || true
}

ensure_ports_open() {
  # We can only do best-effort on the host firewall; cloud security groups are out of scope.
  if have ufw && sudo ufw status >/dev/null 2>&1; then
    if sudo ufw status | grep -qi "Status: active"; then
      log "Opening ports 80/443 via ufw (best-effort)..."
      sudo ufw allow 80/tcp >/dev/null 2>&1 || true
      sudo ufw allow 443/tcp >/dev/null 2>&1 || true
    fi
  fi
}

install_helm() {
  log "Checking Helm..."
  if ! have helm; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

install_ingress() {
  log "Installing ingress-nginx (hostNetwork for direct 443)..."
  k create ns ingress-nginx 2>/dev/null || true

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update >/dev/null 2>&1 || true

  helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
    --set controller.kind=DaemonSet \
    --set controller.hostNetwork=true \
    --set controller.dnsPolicy=ClusterFirstWithHostNet \
    --set controller.service.type=ClusterIP \
    --set controller.admissionWebhooks.enabled=false \
    --wait --timeout=5m

  log "Verifying port 443 is listening..."
  sleep 5
  if ss -tlnp 2>/dev/null | grep -q ":443"; then
    log "Port 443 is listening."
  else
    warn "Port 443 not detected on the host yet. If UI isn't reachable, check firewall/security group and ingress pods."
  fi
}

create_namespaces() {
  log "Creating namespaces..."
  k create ns runai-backend 2>/dev/null || true
  k create ns runai 2>/dev/null || true
  k create ns monitoring 2>/dev/null || true
}

generate_certs_and_secrets() {
  log "Generating self-signed CA + server certs..."
  rm -rf "${CERT_DIR}"
  mkdir -p "${CERT_DIR}"

  (
    cd "${CERT_DIR}"
    openssl req -x509 -new -nodes -days 3650 -newkey rsa:4096 \
      -keyout ca.key -out ca.crt -subj "/CN=RunAI CA" >/dev/null 2>&1

    openssl req -new -nodes -newkey rsa:2048 \
      -keyout server.key -out server.csr -subj "/CN=${DOMAIN}" >/dev/null 2>&1

    cat > server.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}
EOF

    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
      -out server.crt -days 365 -sha256 -extfile server.ext >/dev/null 2>&1

    cat server.crt ca.crt > bundle.crt
  )

  log "Trusting CA on the instance (for curl/helm)..."
  sudo cp "${CERT_DIR}/ca.crt" /usr/local/share/ca-certificates/runai-ca.crt 2>/dev/null || true
  sudo update-ca-certificates >/dev/null 2>&1 || true
  cp "${CERT_DIR}/ca.crt" "${HOME}/runai-ca.crt"

  log "Creating Kubernetes TLS/CA secrets..."
  k delete secret runai-backend-tls runai-ca-cert -n runai-backend 2>/dev/null || true
  k delete secret runai-ca-cert -n runai 2>/dev/null || true

  k create secret tls runai-backend-tls -n runai-backend \
    --cert="${CERT_DIR}/bundle.crt" --key="${CERT_DIR}/server.key"

  k create secret generic runai-ca-cert -n runai-backend \
    --from-file=runai-ca.pem="${CERT_DIR}/ca.crt"

  k create secret generic runai-ca-cert -n runai \
    --from-file=runai-ca.pem="${CERT_DIR}/ca.crt"
}

install_prometheus() {
  log "Installing Prometheus (kube-prometheus-stack)..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update >/dev/null 2>&1 || true

  helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n monitoring \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait --timeout=10m
}

install_knative() {
  log "Installing Knative Serving..."
  k apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-crds.yaml >/dev/null 2>&1 || true
  sleep 3
  k apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-core.yaml >/dev/null 2>&1 || true
  k apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-hpa.yaml >/dev/null 2>&1 || true

  k wait --for=condition=ready pod -l app=controller -n knative-serving --timeout=180s 2>/dev/null || true
  k patch configmap/config-features -n knative-serving --type merge \
    -p '{"data":{"kubernetes.podspec-schedulername":"enabled","kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-affinity":"enabled","kubernetes.podspec-tolerations":"enabled","multi-container":"enabled"}}' \
    >/dev/null 2>&1 || true
}

configure_dns() {
  log "Configuring CoreDNS hosts entry for ${DOMAIN}..."
  INGRESS_IP="$(k get svc -n ingress-nginx -o jsonpath="{.items[0].spec.clusterIP}" 2>/dev/null || echo "10.152.183.1")"

  k apply -f - <<COREDNS
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        hosts {
           ${INGRESS_IP} ${DOMAIN}
           fallthrough
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa { pods insecure; fallthrough in-addr.arpa ip6.arpa; ttl 30; }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
COREDNS

  k rollout restart deployment coredns -n kube-system >/dev/null 2>&1 || true
}

add_runai_repo() {
  log "Adding RunAI control-plane Helm repo..."
  helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
  helm repo update >/dev/null 2>&1 || true
}

write_instructions() {
  cat > "${HOME}/INSTRUCTIONS.md" <<EOF
# RunAI Setup Instructions (Brev Instance)

Public IP: ${PUBLIC_IP}
Domain: ${DOMAIN}
RunAI Version: ${VERSION}
Cert dir: ${CERT_DIR}

## 1) Set JFrog token (required)

Get your JFrog token from Run:AI support, then on the Brev instance:

\`\`\`bash
export RUNAI_JFROG_TOKEN="your-token-here"
\`\`\`

## 2) Deploy RunAI (control plane + add cluster)

This runs **inside** the Brev instance after setting \`RUNAI_JFROG_TOKEN\`:

\`\`\`bash
chmod +x deploy_runai.sh
./deploy_runai.sh
\`\`\`

## 3) Local access (run on YOUR computer)

\`\`\`bash
echo "${PUBLIC_IP} ${DOMAIN}" | sudo tee -a /etc/hosts
\`\`\`

## 4) Open UI

Open: https://${DOMAIN}

Default credentials:
- Email: test@run.ai
- Password: Abcd!234

If you see an SSL warning, install the CA certificate from \`~/runai-ca.crt\` on your local machine/browser.
EOF
}

log "=== RunAI prerequisites installer ==="
log "Domain: ${DOMAIN}"

ensure_microk8s_running
install_helm
ensure_ports_open
create_namespaces
install_ingress
generate_certs_and_secrets
install_prometheus
install_knative
configure_dns
add_runai_repo
write_instructions

log "Done. Next: set RUNAI_JFROG_TOKEN, then run ./deploy_runai.sh"
log "See ${HOME}/INSTRUCTIONS.md"