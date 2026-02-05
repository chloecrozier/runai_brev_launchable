#!/bin/bash
# RunAI Prerequisites Installer
set -e

DOMAIN="${RUNAI_DOMAIN:-runai.local}"
VERSION="${RUNAI_VERSION:-2.24.37}"
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP")
CERT_DIR=/tmp/runai-certs

echo "=== RunAI Prerequisites Installer ==="

# 1. Start MicroK8s (fix containerd if needed)
echo "[1/10] Checking MicroK8s..."

# Fix containerd configs (both MicroK8s and system)
fix_containerd() {
  # Fix MicroK8s containerd configs
  sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /var/snap/microk8s/current/args/containerd*.toml 2>/dev/null || true
  # Fix system containerd config (conflicts with MicroK8s)
  if [ -f /etc/containerd/config.toml ]; then
    sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /etc/containerd/config.toml 2>/dev/null || true
    # If file only has bad config, replace with minimal valid config
    if grep -q 'disabled_plugins = \["cri"\]' /etc/containerd/config.toml 2>/dev/null; then
      echo "version = 2" | sudo tee /etc/containerd/config.toml > /dev/null
    fi
  fi
}

# Apply fix preemptively
fix_containerd

# Try to start, retry with fix if fails
if ! microk8s status 2>/dev/null | grep -q "is running"; then
  echo "Starting MicroK8s..."
  if ! microk8s start 2>/dev/null; then
    echo "Start failed, applying containerd fix and retrying..."
    fix_containerd
    microk8s start
  fi
  sleep 10
fi

# Wait for node to be ready
echo "Waiting for Kubernetes to be ready..."
for i in {1..30}; do
  if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    echo "Node is ready!"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 5
done
kubectl wait --for=condition=ready node --all --timeout=120s 2>/dev/null || true

# 2. Install Helm
echo "[2/10] Checking Helm..."
command -v helm &>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 3. Install Ingress (hostNetwork for port 443 access)
echo "[3/10] Installing Ingress..."
kubectl create ns ingress-nginx 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.kind=DaemonSet --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet --set controller.service.type=ClusterIP \
  --set controller.admissionWebhooks.enabled=false --wait --timeout=3m

# Verify port 443 is listening
echo "Verifying port 443..."
sleep 5
ss -tlnp | grep -q ":443" && echo "Port 443 is listening" || echo "Warning: Port 443 not detected"

# 4. Create namespaces
echo "[4/10] Creating namespaces..."
kubectl create ns runai-backend 2>/dev/null || true
kubectl create ns runai 2>/dev/null || true

# 5. Generate TLS certs
echo "[5/10] Generating certificates..."
rm -rf $CERT_DIR && mkdir -p $CERT_DIR && cd $CERT_DIR
openssl req -x509 -new -nodes -days 3650 -newkey rsa:4096 -keyout ca.key -out ca.crt -subj "/CN=RunAI CA" 2>/dev/null
openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr -subj "/CN=${DOMAIN}" 2>/dev/null
echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -sha256 -extfile server.ext 2>/dev/null
cat server.crt ca.crt > bundle.crt
sudo cp ca.crt /usr/local/share/ca-certificates/runai-ca.crt && sudo update-ca-certificates 2>/dev/null
cp ca.crt ~/runai-ca.crt

# 6. Create K8s secrets
echo "[6/10] Creating secrets..."
kubectl delete secret runai-backend-tls runai-ca-cert -n runai-backend 2>/dev/null || true
kubectl delete secret runai-ca-cert -n runai 2>/dev/null || true
kubectl create secret tls runai-backend-tls -n runai-backend --cert=bundle.crt --key=server.key
kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=ca.crt
kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=ca.crt

# 7. Install Prometheus
echo "[7/10] Installing Prometheus..."
kubectl create ns monitoring 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout=5m

# 8. Install Knative
echo "[8/10] Installing Knative..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-crds.yaml 2>/dev/null || true
sleep 3
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-core.yaml 2>/dev/null || true
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-hpa.yaml 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=controller -n knative-serving --timeout=120s 2>/dev/null || true
kubectl patch configmap/config-features -n knative-serving --type merge -p '{"data":{"kubernetes.podspec-schedulername":"enabled","kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-affinity":"enabled","kubernetes.podspec-tolerations":"enabled","multi-container":"enabled"}}' 2>/dev/null || true

# 9. Configure CoreDNS
echo "[9/10] Configuring DNS..."
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

# 10. Add Helm repo
echo "[10/10] Adding RunAI repo..."
helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
helm repo update

# Generate instructions
cat > ~/INSTRUCTIONS.md <<EOF
# RunAI Setup Instructions
Public IP: ${PUBLIC_IP} | Domain: ${DOMAIN}

## 1. Set JFrog Token
export RUNAI_JFROG_TOKEN="your-token-here"

## 2. Create Registry Secret
kubectl create secret docker-registry runai-reg-creds -n runai-backend \\
  --docker-server=runai.jfrog.io --docker-username=self-hosted-image-puller-prod \\
  --docker-password="\${RUNAI_JFROG_TOKEN}" --docker-email=support@run.ai

## 3. Install Control Plane
helm upgrade -i runai-backend runai-backend/control-plane -n runai-backend \\
  --version "${VERSION}" --set global.domain=${DOMAIN} \\
  --set global.customCA.enabled=true --set-file global.customCA.caPEM=${CERT_DIR}/ca.crt \\
  --set global.imagePullSecrets[0].name=runai-reg-creds --wait --timeout=20m

## 4. Local Access (run on YOUR computer)
echo "${PUBLIC_IP} ${DOMAIN}" | sudo tee -a /etc/hosts

## 5. Open UI: https://${DOMAIN}
Login: test@run.ai / Abcd!234

## 6. Add Cluster (from UI, add this flag):
--set-file customCA.caPEM=${CERT_DIR}/ca.crt
EOF

echo ""
echo "=== Done! Read ~/INSTRUCTIONS.md for next steps ==="
echo "cat ~/INSTRUCTIONS.md"