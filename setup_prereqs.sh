#!/bin/bash
# Runs automatically on instance creation. Sets up everything needed before the user gets access.
set -euo pipefail

DOMAIN="${RUNAI_DOMAIN:-runai.local}"
VERSION="${RUNAI_VERSION:-2.24.37}"
CERT_DIR="${RUNAI_CERT_DIR:-/tmp/runai-certs}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# --- Fix containerd and start MicroK8s ---
log "Fixing containerd..."
sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' \
  /var/snap/microk8s/current/args/containerd*.toml 2>/dev/null || true
if [ -f /etc/containerd/config.toml ]; then
  sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' \
    /etc/containerd/config.toml 2>/dev/null || true
fi

log "Waiting for MicroK8s..."
for i in $(seq 1 60); do
  microk8s status 2>/dev/null | grep -q "is running" && break
  microk8s start 2>/dev/null || true
  sleep 5
done
microk8s status --wait-ready --timeout 300

log "Waiting for node Ready..."
kubectl wait --for=condition=ready node --all --timeout=300s

# --- Helm ---
log "Installing Helm..."
command -v helm &>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- Ingress (hostNetwork for port 443) ---
log "Installing Ingress..."
kubectl create ns ingress-nginx 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.kind=DaemonSet --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet --set controller.service.type=ClusterIP \
  --set controller.admissionWebhooks.enabled=false --wait --timeout=3m

# --- Namespaces ---
log "Creating namespaces..."
kubectl create ns runai-backend 2>/dev/null || true
kubectl create ns runai 2>/dev/null || true

# --- TLS certs ---
log "Generating TLS certificates..."
rm -rf "${CERT_DIR}" && mkdir -p "${CERT_DIR}" && cd "${CERT_DIR}"
openssl req -x509 -new -nodes -days 3650 -newkey rsa:4096 -keyout ca.key -out ca.crt -subj "/CN=RunAI CA" 2>/dev/null
openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr -subj "/CN=${DOMAIN}" 2>/dev/null
cat > server.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -sha256 -extfile server.ext 2>/dev/null
cat server.crt ca.crt > bundle.crt
sudo cp ca.crt /usr/local/share/ca-certificates/runai-ca.crt && sudo update-ca-certificates 2>/dev/null || true
cp ca.crt ~/runai-ca.crt

# --- K8s secrets ---
log "Creating K8s secrets..."
kubectl delete secret runai-backend-tls runai-ca-cert -n runai-backend 2>/dev/null || true
kubectl delete secret runai-ca-cert -n runai 2>/dev/null || true
kubectl create secret tls runai-backend-tls -n runai-backend --cert=bundle.crt --key=server.key
kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=ca.crt
kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=ca.crt

# --- Prometheus ---
log "Installing Prometheus..."
kubectl create ns monitoring 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout=5m

# --- Knative ---
log "Installing Knative..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-crds.yaml 2>/dev/null || true
sleep 3
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-core.yaml 2>/dev/null || true
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-hpa.yaml 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=controller -n knative-serving --timeout=120s 2>/dev/null || true
kubectl patch configmap/config-features -n knative-serving --type merge -p '{"data":{"kubernetes.podspec-schedulername":"enabled","kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-affinity":"enabled","kubernetes.podspec-tolerations":"enabled","multi-container":"enabled"}}' 2>/dev/null || true

# --- Host DNS (so curl from the instance can resolve the domain) ---
log "Adding ${DOMAIN} to /etc/hosts..."
grep -q "${DOMAIN}" /etc/hosts 2>/dev/null || echo "127.0.0.1 ${DOMAIN}" | sudo tee -a /etc/hosts >/dev/null

# --- CoreDNS ---
log "Configuring CoreDNS..."
INGRESS_IP=$(kubectl get svc -n ingress-nginx -o jsonpath="{.items[0].spec.clusterIP}" 2>/dev/null || echo "10.152.183.1")
kubectl apply -f - <<COREDNS
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
kubectl rollout restart deployment coredns -n kube-system 2>/dev/null || true

# --- RunAI Helm repo ---
log "Adding RunAI Helm repo..."
helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
helm repo update

log "Prerequisites ready."
