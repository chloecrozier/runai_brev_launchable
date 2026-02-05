# RunAI Self-Hosted Deployment on Brev

Deploy Run:AI control plane and cluster on a single GPU node using Brev.

## Overview

This guide walks you through deploying RunAI on a Brev launchable instance. The deployment consists of:

1. **Prerequisites Setup** - Automated via `deploy_runai.sh`
2. **Control Plane Installation** - Manual helm command with your JFrog token
3. **Local Access Configuration** - Configure your machine to access the UI
4. **Cluster Registration** - Add the cluster via the RunAI UI
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

# Run the installer
chmod +x deploy_runai.sh
./deploy_runai.sh
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

### Step 4: Create Registry Secret

```bash
kubectl create secret docker-registry runai-reg-creds -n runai-backend \
  --docker-server=runai.jfrog.io \
  --docker-username=self-hosted-image-puller-prod \
  --docker-password="${RUNAI_JFROG_TOKEN}" \
  --docker-email=support@run.ai
```

### Step 5: Install RunAI Control Plane

```bash
helm upgrade -i runai-backend runai-backend/control-plane -n runai-backend \
  --version "2.24.37" \
  --set global.domain=${RUNAI_DOMAIN:-runai.local} \
  --set global.customCA.enabled=true \
  --set-file global.customCA.caPEM=/tmp/runai-certs/ca.crt \
  --set global.imagePullSecrets[0].name=runai-reg-creds \
  --wait --timeout=20m
```

Monitor the deployment:
```bash
kubectl get pods -n runai-backend -w
```

### Step 6: Configure Local Access

On your **local computer**, add the server to your hosts file:

```bash
# Get the public IP from the server output, then run locally:
echo "YOUR_PUBLIC_IP runai.brev.cloud" | sudo tee -a /etc/hosts
```

### Step 7: Access RunAI UI

Open in your browser: **https://runai.brev.cloud** (or your custom domain)

Default credentials:
- Email: `test@run.ai`
- Password: `Abcd!234`

> **SSL Warning?** Install the CA certificate from `~/runai-ca.crt` in your browser.

### Step 8: Add Cluster to RunAI

1. In the RunAI UI, navigate to **Settings > Clusters**
2. Click **New Cluster**
3. Follow the wizard and copy the provided helm command
4. Run the command on your server, **adding the CA cert flag**:

```bash
# Example (use the actual command from the UI):
helm install runai-cluster runai/runai-cluster -n runai \
  --set ... \
  --set-file customCA.caPEM=/tmp/runai-certs/ca.crt
```

### Step 9: Install RunAI CLI (Optional)

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
├── deploy_runai.sh      # Prerequisites installer script
├── readme.md            # This file
├── INSTRUCTIONS.md      # Generated after running deploy_runai.sh
└── runai-ca.crt         # Generated CA certificate (copy to local machine if needed)
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