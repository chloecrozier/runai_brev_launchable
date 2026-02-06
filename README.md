# RunAI on Brev

`setup_prereqs.sh` already ran when your instance was created. It installed Helm, Ingress, Prometheus, Knative, TLS certs, and CoreDNS.

## Deploy RunAI

**1. Set your JFrog token** (get this from Run:AI support):

```bash
export RUNAI_JFROG_TOKEN="your-token-here"
```

**2. Run the deploy script:**

```bash
./runai_brev_launchable/deploy_runai.sh
```

This creates the registry secret, installs the control plane, creates a cluster, and installs it.

**3. On your local machine**, add the hosts entry printed at the end:

```bash
echo "YOUR_PUBLIC_IP runai.local" | sudo tee -a /etc/hosts
```

**4. Open** https://runai.local — login: `test@run.ai` / `Abcd!234`

## Configuration

Set these before running `deploy_runai.sh` if you need non-default values:

| Variable | Default |
|---|---|
| `RUNAI_DOMAIN` | `runai.local` |
| `RUNAI_VERSION` | `2.24.37` |
| `RUNAI_CLUSTER_NAME` | `brev-cluster` |

## Troubleshooting

```bash
kubectl get pods -n runai-backend    # control plane pods
kubectl get pods -n runai            # cluster pods
kubectl logs -n runai-backend -l app=runai-backend-frontend
```

If images fail to pull, check your token: `kubectl get secret runai-reg-creds -n runai-backend -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d`
