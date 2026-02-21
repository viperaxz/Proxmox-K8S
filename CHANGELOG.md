# Changelog

All notable changes to this project will be documented in this file.

## [3.0.0] - 2026-02-02 - GitOps & Full Stack Kubernetes

### 🎉 Major Highlights

This release transforms the project from a simple Terraform-only Talos deployment into a **complete GitOps-ready Kubernetes platform** with full observability, ingress, storage, and application management.

---

### 🏗️ Project Restructure

#### New Directory Layout
```
proxmox-k8s/
├── argocd/                    # ArgoCD application definitions & Helm values
│   ├── applications/          # ArgoCD Application manifests
│   ├── helm-charts/           # Custom Helm charts
│   ├── helm-values/           # Helm value overrides
│   └── sealed-secrets/        # Encrypted secrets (safe for Git)
├── config/                    # All configuration files
│   ├── cluster.tfvars         # Terraform variables
│   ├── kubernetes.env         # Kubernetes bootstrap config
│   └── .credentials           # Generated credentials (gitignored)
├── kubernetes/                # Raw Kubernetes manifests
│   ├── infrastructure/        # Network policies, PDBs
│   ├── monitoring/            # Prometheus, Grafana, Loki manifests
│   └── namespaces.yaml        # Namespace definitions
├── scripts/                   # Utility scripts
│   ├── health-check.sh        # Comprehensive cluster health check
│   ├── uninstall.sh           # Clean uninstall script
│   └── cf_token_test.sh       # Cloudflare API token validator
└── terraform/                 # Terraform files (moved from root)
```

---

### ✨ New Components

#### 🔄 ArgoCD GitOps
- **ArgoCD Application Definitions**: Self-managing GitOps deployments
- **Helm Values**: Pre-configured values for ArgoCD and Traefik
- **Central Configuration**: `argocd/values.yaml` for cluster-wide settings

#### 🌐 Ingress & Networking
- **Traefik Ingress Controller**: Full IngressRoute support with TLS
- **MetalLB Load Balancer**: L2 advertisement for bare-metal LoadBalancer services
- **Custom Helm Chart**: `metallb-config` for IPAddressPool configuration
- **Traefik Middlewares**: Security headers, rate limiting, local-only access

#### 📊 Full Observability Stack
- **Prometheus**: Metrics collection with persistent storage
  - Kubelet & cAdvisor scraping
  - Service/pod auto-discovery
  - 15-day retention
- **Grafana**: Visualization dashboards
  - Pre-configured Prometheus datasource
  - Loki log integration ready
  - Sealed secret for credentials
- **Loki**: Log aggregation (7-day retention)
- **Promtail**: DaemonSet log collector for all pods
- **Node Exporter**: Host-level metrics on all nodes
- **Kube State Metrics**: Kubernetes object metrics

#### 💾 Storage
- **NFS Provisioner**: Dynamic PersistentVolume provisioning
  - Custom Helm chart with full RBAC
  - Default StorageClass (`nfs-client`)
  - Configurable NFS server/path

#### 🔐 Secrets Management
- **Sealed Secrets Integration**: Encrypt secrets for Git storage
  - Cloudflare credentials for DNS-01 challenge
  - Grafana admin credentials
  - Documentation for manual secret creation

#### 🖥️ Dashboard
- **Headlamp**: Modern Kubernetes web UI
  - Service account with admin access
  - Traefik IngressRoute

---

### 🛡️ Security Enhancements

#### Network Policies
- **Default deny ingress** for all managed namespaces
- **Namespace-specific policies** for:
  - ArgoCD (server access, internal communication)
  - Monitoring (Prometheus scrape, Grafana/Loki access)
  - Headlamp (Traefik ingress only)

#### Pod Security
- **Namespace labels** for Pod Security Standards:
  - `privileged`: metallb, traefik, nfs-provisioner, monitoring
  - `baseline`: argocd, headlamp

#### TLS Certificates
- **Let's Encrypt integration** via Cloudflare DNS-01 challenge
- **Staging/Production modes** to avoid rate limits during testing
- **Self-signed fallback** for air-gapped environments

---

### 🔧 Utility Scripts

#### `scripts/health-check.sh`
Comprehensive 787-line health check script:
- Node status and resource usage
- Pod health across all namespaces
- ArgoCD application sync status
- Service/endpoint verification
- Storage (PVC/StorageClass) checks
- Monitoring stack validation
- Web endpoint accessibility tests
- Common issue detection (ImagePull, CrashLoop, etc.)
- Color-coded output with pass/warn/fail counters

#### `scripts/uninstall.sh`
Safe uninstall script:
- Removes ArgoCD apps, Helm releases, manifests
- Force-deletes stuck namespaces (finalizer removal)
- Cleans up PVCs and orphaned PVs
- Optional NFS directory cleanup
- Credential file removal
- Modular: can target specific components

#### `scripts/cf_token_test.sh`
Cloudflare API token validator:
- Tests Zone:Read permission
- Tests Zone:DNS:Edit permission
- Creates/verifies/deletes test TXT record
- Validates DNS-01 challenge will work

---

### 📦 Custom Helm Charts

| Chart | Description |
|-------|-------------|
| `metallb-config` | IPAddressPool and L2Advertisement CRs |
| `nfs-provisioner` | Full NFS CSI with RBAC, StorageClass |
| `prometheus` | Complete Prometheus deployment with scrape configs |
| `promtail` | DaemonSet with Kubernetes pod discovery |
| `loki` | Log aggregation configuration |
| `traefik-middlewares` | Security headers, rate limit, IP allowlist |

---

### 🔄 Terraform Improvements

- **Moved to `terraform/` subdirectory** for cleaner project structure
- **New outputs**: `cluster_endpoint`, `cluster_name`
- **MAC address validation** added to variables
- **Remote state backend** template (S3 + DynamoDB) included but commented

---

### 📝 Configuration

#### `config/kubernetes.env`
New unified configuration file:
```bash
DOMAIN="viperax.org"
METALLB_IP_RANGE="192.168.1.230-192.168.1.250"
NFS_SERVER="192.168.1.101"
NFS_PATH="/mnt/hdd"
TLS_MODE="staging"
CLOUDFLARE_EMAIL="..."
CLOUDFLARE_API_TOKEN="..."
```

#### `config/.credentials`
Auto-generated credentials file (gitignored):
- ArgoCD admin password
- Grafana admin password
- Headlamp service account token
- All service URLs

---

### 📚 Documentation

- **README.md**: Complete rewrite with modern formatting
- **Sealed Secrets README**: How-to for secret management
- **Example configs**: `kubernetes.env.example`, `cluster.tfvars`

---

### 🏷️ Namespaces Created

| Namespace | Purpose | Security Level |
|-----------|---------|----------------|
| `metallb-system` | Load balancer | privileged |
| `traefik` | Ingress controller | privileged |
| `nfs-provisioner` | Storage provisioner | privileged |
| `monitoring` | Prometheus/Grafana/Loki | privileged |
| `argocd` | GitOps | baseline |
| `headlamp` | Dashboard | baseline |
| `sealed-secrets` | Secret encryption | baseline |

---

## [2.0.0] - 2026-02-02

### ⚠️ Breaking Changes

- **Terraform Provider Upgrades**: Updated `bpg/proxmox` to `~> 0.89.1` and `siderolabs/talos` to `~> 0.9.0`
- **Talos Factory Images**: Now uses Talos Factory for custom images with QEMU Guest Agent pre-installed
- **Bootstrap Resource**: Changed `talos_cluster_kubeconfig` from data source to resource

### ✨ Features

- **Talos Factory Integration**: Images from `factory.talos.dev` with pre-baked QEMU Guest Agent
- **New Terraform Outputs**: `talos_installer_image`, `controlplane_ips`, `worker_ips`
- **Input Validation**: For node counts and VIP format

### 🔧 Improvements

- **manage_nodes Script Rewrite**: Proper error handling, accepts node names AND IPs
- **Flannel Disable Fix**: Proper handling via `concat()`
- **SSH Auth Fix**: Use `private_key` instead of `password`

### 🔄 Version Updates

| Component | Old | New |
|-----------|-----|-----|
| Talos Linux | v1.5.3 | v1.10.8 |
| Kubernetes | v1.28.2 | v1.33.6 |
| QEMU Guest Agent | 8.1.0 | 10.1.2 |
| Proxmox Provider | 0.81.0 | ~> 0.89.1 |
| Talos Provider | 0.8.1 | ~> 0.9.0 |

---

## [1.x.x] - Previous Releases

See git history for changes prior to this major refactor.
