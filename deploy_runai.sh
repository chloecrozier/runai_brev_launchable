#!/bin/bash
# RunAI Prerequisites Installer
# This script installs all prerequisites for RunAI deployment
set -e

echo "=============================================="
echo "  RunAI Prerequisites Installer"
echo "=============================================="
echo ""

# Configuration
DOMAIN="${RUNAI_DOMAIN:-runai.local}"
RUNAI_VERSION="${RUNAI_VERSION:-2.24.37}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() { echo -e "${GREEN}[STEP]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get IPs
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "YOUR_PUBLIC_IP")
NODE_IP=$(hostname -I | awk '{print $1}')

#-----------------------------------------------
# 1. Check MicroK8s is running
#-----------------------------------------------
print_step "Checking MicroK8s status..."
if ! microk8s status | grep -q "microk8s is running"; then
    print_warn "MicroK8s not running, attempting to start..."
    
    # Fix containerd config if needed (common issue)
    if [ -f /var/snap/microk8s/current/args/containerd.toml ]; then
        sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /var/snap/microk8s/current/args/containerd.toml 2>/dev/null || true
        sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /var/snap/microk8s/current/args/containerd-template.toml 2>/dev/null || true
    fi
    
    microk8s start
    sleep 10
fi

# Wait for node to be ready
print_step "Waiting for Kubernetes node to be ready..."
for i in {1..30}; do
    if kubectl get nodes | grep -q " Ready"; then
        echo "Node is ready!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 5
done

#-----------------------------------------------
# 2. Install Helm if needed
#-----------------------------------------------
print_step "Checking Helm..."
if ! command -v helm &> /dev/null; then
    print_warn "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

#-----------------------------------------------
# 3. Install Ingress Controller
#-----------------------------------------------
print_step "Installing Ingress Controller..."
kubectl create ns ingress-nginx 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.kind=DaemonSet \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP \
  --set controller.admissionWebhooks.enabled=false \
  --wait --timeout=3m

#-----------------------------------------------
# 4. Create namespaces
#-----------------------------------------------
print_step "Creating namespaces..."
kubectl create ns runai-backend 2>/dev/null || true
kubectl create ns runai 2>/dev/null || true

#-----------------------------------------------
# 5. Generate TLS certificates
#-----------------------------------------------
print_step "Generating TLS certificates..."
CERT_DIR=/tmp/runai-certs
rm -rf $CERT_DIR && mkdir -p $CERT_DIR && cd $CERT_DIR

# CA cert
openssl req -x509 -new -nodes -days 3650 -newkey rsa:4096 -keyout ca.key -out ca.crt \
  -subj "/CN=RunAI CA" 2>/dev/null

# Server cert
openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr \
  -subj "/CN=${DOMAIN}" 2>/dev/null
cat > server.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:localhost
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -sha256 -extfile server.ext 2>/dev/null
cat server.crt ca.crt > bundle.crt

# Install CA system-wide
print_step "Installing CA certificate..."
sudo cp ca.crt /usr/local/share/ca-certificates/runai-ca.crt
sudo update-ca-certificates 2>/dev/null
cp ca.crt ~/runai-ca.crt

#-----------------------------------------------
# 6. Create Kubernetes secrets
#-----------------------------------------------
print_step "Creating Kubernetes secrets..."
kubectl delete secret runai-backend-tls -n runai-backend 2>/dev/null || true
kubectl delete secret runai-ca-cert -n runai-backend 2>/dev/null || true
kubectl delete secret runai-ca-cert -n runai 2>/dev/null || true

kubectl create secret tls runai-backend-tls -n runai-backend --cert=bundle.crt --key=server.key
kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=ca.crt
kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=ca.crt

#-----------------------------------------------
# 7. Configure CoreDNS
#-----------------------------------------------
print_step "Configuring DNS..."
INGRESS_IP=$(kubectl get svc -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath="{.items[0].spec.clusterIP}" 2>/dev/null || echo "10.152.183.1")

kubectl apply -f - <<EOF
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
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
EOF
kubectl rollout restart deployment coredns -n kube-system 2>/dev/null || true

#-----------------------------------------------
# 8. Install Knative
#-----------------------------------------------
print_step "Installing Knative Serving..."
KNATIVE_VERSION="v1.18.2"
kubectl apply -f https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml 2>/dev/null || true
sleep 3
kubectl apply -f https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml 2>/dev/null || true
kubectl apply -f https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-hpa.yaml 2>/dev/null || true

# Wait for controller
print_step "Waiting for Knative controller..."
kubectl wait --for=condition=ready pod -l app=controller -n knative-serving --timeout=120s 2>/dev/null || true

# Configure Knative features
kubectl patch configmap/config-features -n knative-serving --type merge --patch '{
  "data": {
    "kubernetes.podspec-schedulername": "enabled",
    "kubernetes.podspec-nodeselector": "enabled",
    "kubernetes.podspec-affinity": "enabled",
    "kubernetes.podspec-tolerations": "enabled",
    "kubernetes.podspec-volumes-emptydir": "enabled",
    "kubernetes.podspec-securitycontext": "enabled",
    "kubernetes.containerspec-addcapabilities": "enabled",
    "kubernetes.podspec-persistent-volume-claim": "enabled",
    "kubernetes.podspec-persistent-volume-write": "enabled",
    "multi-container": "enabled",
    "kubernetes.podspec-init-containers": "enabled"
  }
}' 2>/dev/null || true

#-----------------------------------------------
# 9. Add RunAI Helm repo
#-----------------------------------------------
print_step "Adding RunAI Helm repository..."
helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
helm repo update

#-----------------------------------------------
# 10. Generate INSTRUCTIONS.md
#-----------------------------------------------
print_step "Generating instructions..."

cat > ~/INSTRUCTIONS.md <<EOF
# RunAI Installation Instructions

## Server Information
- **Public IP:** ${PUBLIC_IP}
- **Domain:** ${DOMAIN}
- **CA Certificate:** ~/runai-ca.crt

---

## Step 1: Set Your JFrog Token

Get your JFrog token from Run:AI and export it:

\`\`\`bash
export RUNAI_JFROG_TOKEN="your-jfrog-token-here"
\`\`\`

---

## Step 2: Create Registry Secret

\`\`\`bash
kubectl create secret docker-registry runai-reg-creds -n runai-backend \\
  --docker-server=runai.jfrog.io \\
  --docker-username=self-hosted-image-puller-prod \\
  --docker-password="\${RUNAI_JFROG_TOKEN}" \\
  --docker-email=support@run.ai
\`\`\`

---

## Step 3: Install RunAI Control Plane

\`\`\`bash
helm upgrade -i runai-backend runai-backend/control-plane -n runai-backend \\
  --version "${RUNAI_VERSION}" \\
  --set global.domain=${DOMAIN} \\
  --set global.customCA.enabled=true \\
  --set-file global.customCA.caPEM=/tmp/runai-certs/ca.crt \\
  --set global.imagePullSecrets[0].name=runai-reg-creds \\
  --wait --timeout=20m
\`\`\`

Monitor pod startup:
\`\`\`bash
kubectl get pods -n runai-backend -w
\`\`\`

---

## Step 4: Configure Local Access

On your **local computer**, add this to /etc/hosts:

\`\`\`bash
echo "${PUBLIC_IP} ${DOMAIN}" | sudo tee -a /etc/hosts
\`\`\`

---

## Step 5: Access RunAI UI

Open: **https://${DOMAIN}**

Default credentials: \`test@run.ai\` / \`Abcd!234\`

If you see SSL warnings, install ~/runai-ca.crt in your browser.

---

## Step 6: Add Cluster to RunAI

1. In the RunAI UI, go to **Settings > Clusters > New Cluster**
2. Copy the helm install command provided
3. Run the command on this server, adding the CA cert flag:

\`\`\`bash
# Add this flag to the helm command from the UI:
--set-file customCA.caPEM=/tmp/runai-certs/ca.crt
\`\`\`

---

## Step 7: Install RunAI CLI (Optional)

\`\`\`bash
# Download CLI
wget https://github.com/run-ai/runai-cli/releases/latest/download/runai-cli-linux-amd64 -O runai
chmod +x runai
sudo mv runai /usr/local/bin/

# Configure CLI
runai config set cluster-url https://${DOMAIN}
\`\`\`

---

## Useful Commands

\`\`\`bash
# Check pod status
kubectl get pods -n runai-backend
kubectl get pods -n runai

# View logs
kubectl logs -n runai-backend -l app=runai-backend-frontend

# Restart pods
kubectl delete pods --all -n runai-backend
\`\`\`

---

## Troubleshooting

**Pods stuck in Pending:** Check node status with \`kubectl get nodes\`

**Image pull errors:** Verify your JFrog token is correct

**Can't access UI:** Ensure port 443 is open and /etc/hosts is configured

EOF

cd ~

echo ""
echo "=============================================="
echo -e "${GREEN}  Prerequisites installed successfully!${NC}"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Read ~/INSTRUCTIONS.md for complete setup guide"
echo "  2. Set your JFrog token: export RUNAI_JFROG_TOKEN='your-token'"
echo "  3. Follow the instructions to deploy RunAI"
echo ""
echo "Quick view: cat ~/INSTRUCTIONS.md"
echo ""