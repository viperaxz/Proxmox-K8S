# Proxmox-K8S

🚀 **Automated Talos Kubernetes cluster deployment on Proxmox VE** with a complete observability stack, GitOps-first deployment, and secure ingress.

Deploy a production-ready 6-node Kubernetes cluster (3 control planes + 3 workers) with full GitOps automation.

## ✨ What You Get

| Component | Description |
|-----------|-------------|
| **Talos Linux** | Immutable, secure Kubernetes OS (no SSH, minimal attack surface) |
| **High Availability** | 3 control plane nodes with Virtual IP |
| **GitOps (ArgoCD)** | All services deployed and managed via ArgoCD |
| **Automatic SSL** | Let's Encrypt certificates via Cloudflare DNS |
| **Load Balancing** | MetalLB for bare-metal LoadBalancer services |
| **Persistent Storage** | NFS-backed dynamic provisioning |
| **Full Observability** | Prometheus, Grafana, Loki, Promtail |
| **Sealed Secrets** | GitOps-safe encrypted secrets |
| **Web Dashboard** | Headlamp for cluster management |

## 📁 Project Structure

```
Proxmox-K8S/
├── terraform/                 # Infrastructure as Code (Proxmox VMs)
│   ├── main.tf
│   ├── variables.tf
│   ├── talos_*.tf            # Talos cluster resources
│   └── configs/              # Talos machine configs
├── argocd/                    # GitOps Configuration (NEW)
│   ├── bootstrap.sh          # Minimal bootstrap script
│   ├── applications/         # ArgoCD Application manifests
│   ├── helm-charts/          # Custom Helm charts
│   ├── helm-values/          # Values for external charts
│   └── sealed-secrets/       # Encrypted secrets (safe for Git)
├── kubernetes/               # Raw manifests (used by ArgoCD)
│   ├── namespaces.yaml
│   ├── infrastructure/
│   │   └── network-policies/
│   └── monitoring/
│       ├── kube-state-metrics/
│       └── node-exporter/
├── scripts/
│   ├── uninstall.sh          # Clean uninstall script
│   └── cf_token_test.sh      # Cloudflare token tester
└── config/
    ├── config.env            # Proxmox credentials
    ├── kubernetes.env        # Kubernetes service config
    ├── cluster.tfvars        # Cluster settings
    └── .credentials          # Generated credentials (gitignored)
```

---

## 📋 Prerequisites

### Required Tools

Install these on your local machine:

```bash
# Update system
sudo apt update && sudo apt install -y curl wget git

# Terraform (for Proxmox VM provisioning)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# kubectl (Kubernetes CLI)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# talosctl (Talos CLI)
curl -sL https://talos.dev/install | sh

# Helm (package manager)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubeseal (for Sealed Secrets)
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c 2-)
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm -f kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
```

### Proxmox VE Setup

1. **Enable SSH** on your Proxmox host (required for Terraform)

2. **Create API Token:**
   - Datacenter → Permissions → API Tokens → Add
   - User: `root@pam`
   - Token ID: `terraform`
   - Privilege Separation: **unchecked**
   - Copy the token (format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

3. **Setup NFS Storage** (for persistent volumes):
   ```bash
   # On Proxmox host
   apt install -y nfs-kernel-server
   mkdir -p /mnt/pve/nfs-kubernetes
   echo "/mnt/pve/nfs-kubernetes *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
   exportfs -ra
   systemctl restart nfs-kernel-server
   ```

### Cloudflare Setup

1. Add your domain to Cloudflare (free tier works)
2. Create an API Token:
   - Go to: [Cloudflare Dashboard](https://dash.cloudflare.com) → My Profile → API Tokens
   - Click "Create Token"
   - Use template: **"Edit zone DNS"**
   - Zone Resources: Include → Specific zone → **Your domain**
   - Save the token

### Network Planning

Reserve these static IPs in your router/DHCP:

| Purpose | Count | Example IPs |
|---------|-------|-------------|
| Virtual IP (VIP) | 1 | `192.168.1.50` |
| Control Planes | 3 | `192.168.1.51`, `.52`, `.53` |
| Worker Nodes | 3 | `192.168.1.61`, `.62`, `.63` |
| LoadBalancer (MetalLB) | 1+ | `192.168.1.230` |

---

## 🚀 Installation

### Phase 1: Provision Kubernetes Cluster

#### Step 1: Clone Repository

```bash
git clone https://github.com/viperaxz/Proxmox-K8S.git
cd Proxmox-K8S
```

#### Step 2: Configure Proxmox Connection

```bash
cp config/config.env.example config/config.env
```

Edit `config/config.env`:
```bash
export PROXMOX_VE_ENDPOINT="https://192.168.1.10:8006"
export PROXMOX_VE_INSECURE="true"
export PROXMOX_VE_API_TOKEN="root@pam!terraform=YOUR-TOKEN-HERE"
export PROXMOX_VE_SSH_AGENT="true"
export PROXMOX_VE_SSH_USERNAME="root"
```

#### Step 3: Configure Cluster Settings

Edit `config/cluster.tfvars`:

```hcl
# Proxmox Connection
proxmox_hostname     = "192.168.1.10"              # Your Proxmox IP
proxmox_ssh_key_path = "/home/youruser/.ssh/id_rsa" # FULL path (no ~)

# Network Configuration
talos_virtual_ip       = "192.168.1.50"   # HA Virtual IP
controlplane_ip_prefix = "192.168.1.5"    # Creates .51, .52, .53
workernode_ip_prefix   = "192.168.1.6"    # Creates .61, .62, .63

# Resources (adjust to your hardware)
controlplane_cpu_cores = 2
controlplane_memory    = 3072             # 3GB per control plane
workernode_cpu_cores   = 4
workernode_memory      = 8192             # 8GB per worker
```

#### Step 4: Deploy Cluster with Terraform

```bash
# Load Proxmox credentials
source config/config.env

# Initialize and deploy
cd terraform
terraform init
terraform apply -var-file=../config/cluster.tfvars

# Type 'yes' when prompted
# Wait 5-10 minutes for cluster to be ready
```

#### Step 5: Configure kubectl Access

```bash
# Create config directories
mkdir -p ~/.kube ~/.talos

# Export configurations from Terraform
terraform output -raw kubeconfig > ~/.kube/config
terraform output -raw talosconfig > ~/.talos/config
chmod 600 ~/.kube/config ~/.talos/config

# Verify cluster is ready
kubectl get nodes
```

Expected output (all nodes Ready):
```
NAME          STATUS   ROLES           AGE   VERSION
k8s-cp-1      Ready    control-plane   5m    v1.32.0
k8s-cp-2      Ready    control-plane   5m    v1.32.0
k8s-cp-3      Ready    control-plane   5m    v1.32.0
k8s-worker-1  Ready    <none>          5m    v1.32.0
k8s-worker-2  Ready    <none>          5m    v1.32.0
k8s-worker-3  Ready    <none>          5m    v1.32.0
```

#### Step 5.1: Approve Kubelet CSRs (Required)

Talos with kubelet server certificate rotation requires manual CSR approval. After the cluster is up:

```bash
# Check for pending CSRs
kubectl get csr

# Approve all pending CSRs
kubectl get csr -o name | xargs -I {} kubectl certificate approve {}
```

> ⚠️ **Important**: Without this step, `kubectl exec`, `kubectl logs`, and metrics collection will fail with TLS errors. CSRs may also appear after node restarts.

#### Step 5.2: Verify Cluster Health

Run the comprehensive health check script:

```bash
./scripts/health-check.sh --quick
```

Or perform manual verification:

```bash
# 1. Check all nodes are Ready with no pressure conditions
kubectl get nodes -o wide
kubectl describe nodes | grep -A5 "Conditions:"

# 2. Check Talos cluster health (from any control plane)
talosctl -n <CONTROL_PLANE_IP> health

# 3. Verify etcd cluster (should show 3 members)
talosctl -n <CONTROL_PLANE_IP> etcd members

# 4. Check all system pods are running
kubectl get pods -n kube-system

# 5. Test API server health
kubectl get --raw='/healthz'
kubectl get --raw='/readyz'

# 6. Test pod scheduling and DNS (creates temporary pod)
kubectl run test-nginx --image=nginx:alpine --restart=Never
kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s
kubectl exec test-nginx -- nslookup kubernetes.default.svc.cluster.local
kubectl delete pod test-nginx
```

#### Expected Results After Phase 1

| Check | Expected Result |
|-------|-----------------|
| Nodes | 6 nodes Ready (3 control-plane, 3 worker) |
| Node Conditions | No MemoryPressure, DiskPressure, or PIDPressure |
| kube-system pods | ~23 pods Running (coredns, flannel, proxy, apiserver, etc.) |
| etcd members | 3 members, all healthy |
| Talos health | All checks pass |
| DNS | CoreDNS resolving `kubernetes.default.svc.cluster.local` |
| API Server | `/healthz` and `/readyz` return `ok` |
| Storage | ⚠️ No StorageClass (expected - configured in Phase 2) |
| ArgoCD | ⚠️ Not deployed (expected - deployed in Phase 2) |

> ✅ **Ready for Phase 2**: If all checks pass, proceed to deploy services via GitOps.

---

### Phase 2: Deploy Services via GitOps

#### Step 6: Configure Kubernetes Services

```bash
cd ..  # Back to repo root
cp config/kubernetes.env.example config/kubernetes.env
```

Edit `config/kubernetes.env`:
```bash
# Your domain (must be managed in Cloudflare)
DOMAIN="example.com"

# MetalLB LoadBalancer IP(s)
METALLB_IP_RANGE="192.168.1.230-192.168.1.230"

# NFS Storage (your Proxmox IP or NAS)
NFS_SERVER="192.168.1.10"
NFS_PATH="/mnt/pve/nfs-kubernetes"

# TLS Mode: letsencrypt, staging, or selfsigned
TLS_MODE="staging"    # Use staging first to avoid rate limits

# Cloudflare credentials (for Let's Encrypt DNS challenge)
CLOUDFLARE_EMAIL="your-email@example.com"
CLOUDFLARE_API_TOKEN="your-cloudflare-api-token"

# Leave empty to auto-generate
GRAFANA_ADMIN_PASSWORD=""
```

#### Step 7: Run Bootstrap Script

```bash
./argocd/bootstrap.sh
```

This minimal bootstrap:
1. ✅ Creates all namespaces
2. ✅ Installs Sealed Secrets controller
3. ✅ Creates encrypted secrets (Cloudflare, Grafana)
4. ✅ Installs ArgoCD via Helm
5. ✅ Deploys App of Apps (triggers GitOps)

ArgoCD then automatically deploys everything else:
- MetalLB (LoadBalancer)
- Traefik (Ingress + TLS)
- NFS Provisioner (Storage)
- Prometheus, Grafana, Loki, Promtail (Monitoring)
- Headlamp (Dashboard)
- Network Policies, PDBs

#### Step 8: Configure DNS

Add a **wildcard DNS record** pointing to your LoadBalancer IP:

**Option A: Local DNS (Pi-hole/AdGuard/Router)**
```
*.example.com → 192.168.1.230
```

**Option B: Cloudflare (for external access)**
```
Type: A
Name: *
Content: YOUR_PUBLIC_IP (with port forwarding)
Proxied: OFF (grey cloud for wildcard)
```

---

## 🌐 Accessing Services

### Service URLs

All credentials are saved to `config/.credentials` after bootstrap.

| Service | URL | Description |
|---------|-----|-------------|
| **ArgoCD** | `https://argocd.DOMAIN` | GitOps dashboard - manage all deployments |
| **Grafana** | `https://grafana.DOMAIN` | Metrics dashboards |
| **Prometheus** | `https://prometheus.DOMAIN` | Metrics database & queries |
| **Traefik** | `https://traefik.DOMAIN` | Ingress controller dashboard |
| **Headlamp** | `https://headlamp.DOMAIN` | Kubernetes web dashboard |

### Credentials

After running `./argocd/bootstrap.sh`, all credentials are saved to:

```bash
cat config/.credentials
```

| Service | Username | How to Get Password |
|---------|----------|---------------------|
| **ArgoCD** | `admin` | Saved in `config/.credentials` |
| **Grafana** | `admin` | Saved in `config/.credentials` |
| **Headlamp** | *(token)* | 24h token saved in `config/.credentials` |

### Regenerating Headlamp Token

The Headlamp token expires after 24 hours. To regenerate:

```bash
# Generate new 24-hour token
kubectl create token headlamp-admin -n headlamp --duration=24h

# Or generate 7-day token
kubectl create token headlamp-admin -n headlamp --duration=168h
```

---

## 🔧 Management

### Health Monitoring

#### Quick Health Check

```bash
# Run comprehensive health check
./scripts/health-check.sh --quick

# Full health check (includes endpoint tests)
./scripts/health-check.sh
```

#### Manual Health Checks

```bash
# Check all nodes
kubectl get nodes -o wide

# Check for any unhealthy pods
kubectl get pods -A | grep -v Running | grep -v Completed

# Check node conditions (pressure, etc.)
kubectl describe nodes | grep -A5 "Conditions:"

# Check Talos cluster health
talosctl -n <CONTROL_PLANE_IP> health

# Check etcd cluster
talosctl -n <CONTROL_PLANE_IP> etcd members

# Check pending CSRs (approve if needed)
kubectl get csr
kubectl get csr -o name | xargs -I {} kubectl certificate approve {}
```

### ArgoCD Sync Operations

#### Check Sync Status

```bash
# List all applications with status
kubectl get applications -n argocd

# Detailed status
kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"

# Check specific app details
kubectl describe application <app-name> -n argocd
```

#### Manual Sync

```bash
# Sync a single application
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Sync all applications
for app in $(kubectl get applications -n argocd -o name); do
  kubectl patch $app -n argocd --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
done

# Hard refresh (clear cache and sync)
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"},"info":[{"name":"Reason","value":"Manual refresh"}]}}'
```

#### Enable/Disable Auto-Sync

Auto-sync is enabled by default in `argocd/apps/app-of-apps.yaml`. To toggle:

```bash
# Disable auto-sync for an app
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"spec":{"syncPolicy":null}}'

# Re-enable auto-sync
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### ArgoCD CLI Operations

```bash
# Login to ArgoCD CLI (optional)
argocd login argocd.DOMAIN --username admin --password <password>

# List apps
argocd app list

# Sync an app
argocd app sync <app-name>

# Get app details
argocd app get <app-name>
```

### ArgoCD Web UI

Access at `https://argocd.DOMAIN`:
- **Applications**: View all apps, sync status, health
- **Settings**: Repositories, clusters, projects
- **User Info**: Account settings, tokens

### Terraform Operations

```bash
cd terraform
source ../config/config.env

terraform plan -var-file=../config/cluster.tfvars   # Preview changes
terraform apply -var-file=../config/cluster.tfvars  # Apply changes
terraform destroy -var-file=../config/cluster.tfvars # Destroy cluster
```

### Talos Operations

```bash
# Check node health
talosctl -n 192.168.1.51 health

# View system logs
talosctl -n 192.168.1.51 logs kubelet

# Upgrade Talos (one node at a time)
talosctl -n 192.168.1.51 upgrade --image ghcr.io/siderolabs/installer:v1.9.0
```

### Kubectl Operations

```bash
# Check all pods
kubectl get pods -A

# Check pod status by namespace
kubectl get pods -n monitoring
kubectl get pods -n argocd
kubectl get pods -n traefik

# View logs
kubectl logs -n traefik deployment/traefik
kubectl logs -n argocd deployment/argocd-server

# Check certificates
kubectl get certificates -A
```

### Uninstall Everything

To completely remove all deployed services (keeps the cluster):

```bash
./scripts/uninstall.sh
```

This removes all namespaces, Helm releases, and ArgoCD applications in ~30 seconds.

---

## 🔄 GitOps Workflow

After initial bootstrap, all changes should be made via Git:

### Making Changes

1. **Edit configuration** in `argocd/helm-charts/*/values.yaml`
2. **Commit and push** to Git:
   ```bash
   git add -A
   git commit -m "Update Grafana settings"
   git push origin main
   ```
3. **ArgoCD detects changes** and shows "OutOfSync"
4. **Sync in ArgoCD UI** (or enable auto-sync)

### Enable Auto-Sync

To enable automatic deployment on git push, edit `argocd/apps/app-of-apps.yaml`:

```yaml
syncPolicy:
  automated:
    prune: true      # Remove deleted resources
    selfHeal: true   # Revert manual changes
```

---

## 🔒 Security Features

| Feature | Description |
|---------|-------------|
| **Talos Linux** | No SSH, read-only root filesystem, minimal attack surface |
| **Sealed Secrets** | Secrets encrypted in Git, only decryptable by cluster |
| **Network Policies** | Namespace isolation, only required traffic allowed |
| **TLS Everywhere** | All ingress encrypted with Let's Encrypt |
| **RBAC** | Minimal permissions per service |

---

## 🐛 Troubleshooting

### Nodes Not Becoming Ready

```bash
# Check Talos health
talosctl -n 192.168.1.51 health

# Check kubelet logs
talosctl -n 192.168.1.51 logs kubelet

# Check etcd status
talosctl -n 192.168.1.51 etcd members
```

### Services Returning 404/502

```bash
# Check Traefik logs
kubectl logs -n traefik deployment/traefik

# Check IngressRoutes exist
kubectl get ingressroute -A

# Check service endpoints
kubectl get endpoints -A
```

### SSL Certificate Issues

```bash
# Check certificate status
kubectl get certificates -A
kubectl describe certificate -n traefik

# Check Traefik ACME logs
kubectl logs -n traefik deployment/traefik | grep -i acme

# Test Cloudflare token
./scripts/cf_token_test.sh
```

### ArgoCD Applications Stuck

```bash
# Check application status
kubectl get applications -n argocd

# View sync errors
kubectl describe application <app-name> -n argocd

# Check ArgoCD logs
kubectl logs -n argocd deployment/argocd-application-controller
```

### Pods Stuck in Pending

```bash
# Check events
kubectl describe pod <pod-name> -n <namespace>

# Check storage (NFS issues)
kubectl get pvc -A
kubectl get sc
kubectl describe pvc <pvc-name> -n <namespace>
```

---

## 📊 Resource Requirements

### Minimum Hardware

| Component | CPU | RAM | Storage |
|-----------|-----|-----|---------|
| Control Plane (x3) | 2 cores | 3 GB | 30 GB |
| Worker Node (x3) | 4 cores | 8 GB | 50 GB |
| **Total** | **18 cores** | **33 GB** | **240 GB** |

### Proxmox Host Requirements

- **CPU**: 18+ cores (or overcommit with ratio 2:1)
- **RAM**: 40+ GB (33 GB for VMs + Proxmox overhead)
- **Storage**: 250+ GB (VMs + NFS share)

---

## 📝 TLS Certificate Modes

Set `TLS_MODE` in `config/kubernetes.env`:

| Mode | Use Case | Notes |
|------|----------|-------|
| `staging` | Testing | Fake certs, no rate limits, browser warnings |
| `letsencrypt` | Production | Real certs, 50/week rate limit |
| `selfsigned` | Air-gapped | No external requests, browser warnings |

**Recommendation**: Start with `staging`, switch to `letsencrypt` when everything works.

---

## 🙏 Acknowledgments

This project was originally inspired by and built upon [TJ's Kubernetes Service](https://github.com/zimmertr/TJs-Kubernetes-Service) by [@zimmertr](https://github.com/zimmertr). Thank you for the excellent foundation!

### Technologies Used

- [Talos Linux](https://www.talos.dev/) - Immutable Kubernetes OS
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps continuous delivery
- [Sealed Secrets](https://sealed-secrets.netlify.app/) - Encrypted secrets for Git
- [Traefik](https://traefik.io/) - Cloud native ingress
- [Prometheus](https://prometheus.io/) / [Grafana](https://grafana.com/) / [Loki](https://grafana.com/oss/loki/) - Observability stack
- [MetalLB](https://metallb.universe.tf/) - Bare metal load balancer
- [Headlamp](https://headlamp.dev/) - Kubernetes web UI

---

## 📄 License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

You are free to use, modify, and distribute this software under the terms of the GPL-3.0 license.

