# RunAI Self-Hosted Deployment on Brev

Deploy the Run:AI control plane **and** register the local cluster on a single GPU node using Brev.

## Overview

This guide walks you through deploying RunAI on a Brev launchable instance. The deployment consists of:

1. **Prerequisites Setup** - Automated via `deploy_runai_prereqs.sh`
2. **Set JFrog token** - You export your Run:AI JFrog token
3. **Deploy RunAI** - Automated via `deploy_runai.sh` (registry secret → control plane → add cluster)
4. **Local Access Configuration** - Configure your machine to access the UI
5. **CLI Installation** - Optional command-line tools

---

## Quick Start

### Step 1: Create Brev Instance

Launch a Brev instance with GPU support. The instance should have:
- MicroK8s pre-installed
- NVIDIA GPU operator configured
- At least 32GB RAM recommended

```bash
# Clone this repo or copy the files
git clone <your-repo>
cd <your-repo>
```

### Step 2: Run Prerequisites Installer

```bash
# Optional: Set custom domain (default: runai.local)
export RUNAI_DOMAIN="runai.brev.cloud"

# Optional: Set RunAI version (default: 2.24.37)
export RUNAI_VERSION="2.24.37"

# Run the prerequisites installer
chmod +x deploy_runai_prereqs.sh
./deploy_runai_prereqs.sh
```

This script will:
- Ensure MicroK8s is running
- Install Helm and Ingress controller
- Generate TLS certificates
- Install Knative
- Create all required Kubernetes resources
- Generate `INSTRUCTIONS.md` with next steps

### Step 3: Set Your JFrog Token

Get your JFrog token from Run:AI support, then:

```bash
export RUNAI_JFROG_TOKEN="eyJ2ZXIiOiIyIi..."  # Your full token here
```

### Step 4: Deploy RunAI (control plane + add cluster)

```bash
chmod +x deploy_runai.sh
./deploy_runai.sh
```

What `deploy_runai.sh` does:
- Creates the JFrog registry pull secret in `runai-backend`
- Installs/updates the Run:AI control plane via Helm
- Calls the control plane API to create/register the local cluster
- Installs the cluster components using the returned Helm install string (and injects the custom CA flag)

Optional variables you can override:

```bash
# Control plane UI/API host (defaults to RUNAI_DOMAIN)
export RUNAI_CONTROL_PLANE_DOMAIN="${RUNAI_DOMAIN}"

# Cluster registration info
export RUNAI_CLUSTER_NAME="brev-cluster"
export RUNAI_CLUSTER_VERSION="${RUNAI_VERSION}"

# Credentials for the initial admin (defaults shown)
export RUNAI_USERNAME="test@run.ai"
export RUNAI_PASSWORD="Abcd!234"

# If you *didn't* trust the CA on the instance, you can force curl -k:
export RUNAI_CURL_INSECURE=1
```

### Step 5: Configure Local Access

On your **local computer**, add the server to your hosts file:

```bash
# Get the public IP from the server output, then run locally:
echo "YOUR_PUBLIC_IP runai.brev.cloud" | sudo tee -a /etc/hosts
```

### Step 6: Access RunAI UI

Open in your browser: **https://runai.brev.cloud** (or your custom domain)

Default credentials:
- Email: `test@run.ai`
- Password: `Abcd!234`

> **SSL Warning?** Install the CA certificate from `~/runai-ca.crt` in your browser.

### Step 7: Install RunAI CLI (Optional)

```bash
wget https://github.com/run-ai/runai-cli/releases/latest/download/runai-cli-linux-amd64 -O runai
chmod +x runai
sudo mv runai /usr/local/bin/

# Configure
runai config set cluster-url https://runai.brev.cloud
```

---

## File Structure

```
.
├── deploy_runai_prereqs.sh   # Prereqs: k8s health + ingress + certs + Prometheus + Knative
├── deploy_runai.sh           # Deploy: registry secret + control plane + add/register cluster
├── README.md                 # This file
├── INSTRUCTIONS.md           # Generated after running deploy_runai_prereqs.sh
└── runai-ca.crt              # Generated CA certificate (copy to local machine if needed)
```

---

## Troubleshooting

### MicroK8s Won't Start

If containerd fails to start:
```bash
sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /var/snap/microk8s/current/args/containerd.toml
sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' /var/snap/microk8s/current/args/containerd-template.toml
microk8s start
```

### Pods Stuck in Pending

Check node status:
```bash
kubectl get nodes
kubectl describe node
```

### Image Pull Errors

Verify your JFrog token is complete (should have 3 parts separated by dots):
```bash
kubectl get secret runai-reg-creds -n runai-backend -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

### Can't Access UI

1. Verify port 443 is open on your firewall/security group
2. Check ingress is running: `kubectl get pods -n ingress-nginx`
3. Verify /etc/hosts on your local machine

### Check Available Chart Versions

```bash
helm search repo runai-backend/control-plane --versions
```

---

## Useful Commands

```bash
# Pod status
kubectl get pods -n runai-backend
kubectl get pods -n runai
kubectl get pods -n knative-serving

# Logs
kubectl logs -n runai-backend -l app=runai-backend-frontend
kubectl logs -n runai-backend -l app=keycloak

# Restart all pods
kubectl delete pods --all -n runai-backend

# Check services
kubectl get svc -n runai-backend
kubectl get ingress -n runai-backend
```

---

## Requirements

- Brev instance with GPU
- MicroK8s installed
- Run:AI JFrog token (contact Run:AI support)
- Port 443 accessible from your local machine