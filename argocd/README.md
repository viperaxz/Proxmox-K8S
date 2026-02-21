# ArgoCD GitOps Setup

This directory contains the ArgoCD-based GitOps configuration for the Proxmox-K8S cluster.

## Directory Structure

```
argocd/
├── bootstrap.sh              # Minimal bootstrap script
├── values.yaml               # Central configuration
├── apps/
│   └── app-of-apps.yaml     # Root application
├── applications/             # ArgoCD Application manifests
│   ├── namespaces.yaml
│   ├── metallb.yaml
│   ├── nfs-provisioner.yaml
│   ├── traefik.yaml
│   ├── prometheus.yaml
│   ├── grafana.yaml
│   ├── loki.yaml
│   ├── promtail.yaml
│   ├── headlamp.yaml
│   ├── argocd.yaml          # Self-managed
│   └── ...
├── helm-charts/             # Custom Helm charts
│   ├── metallb-config/
│   ├── nfs-provisioner/
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   ├── promtail/
│   ├── headlamp/
│   └── pdbs/
├── helm-values/             # Values for external Helm charts
│   ├── traefik.yaml
│   └── argocd.yaml
└── sealed-secrets/          # Encrypted secrets (safe for Git)
```

## Prerequisites

Install these tools before running bootstrap:

```bash
# kubectl (if not already installed)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubeseal (for Sealed Secrets)
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c 2-)
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

## Quick Start

1. **Configure your environment:**
   ```bash
   cp config/kubernetes.env.example config/kubernetes.env
   # Edit config/kubernetes.env with your values
   ```

2. **Run bootstrap:**
   ```bash
   ./argocd/bootstrap.sh
   ```

3. **Access ArgoCD:**
   ```
   URL: https://argocd.<your-domain>
   User: admin
   Password: <shown in output, also saved to config/.credentials>
   ```

4. **Sync applications:**
   - Open ArgoCD UI
   - Click "Sync" on each application (or use "Sync All")

## What Bootstrap Does

The bootstrap script does the **minimum** required:

1. Creates namespaces
2. Installs Sealed Secrets controller
3. Creates encrypted secrets (Cloudflare, Grafana)
4. Installs ArgoCD
5. Deploys the "App of Apps"

ArgoCD then takes over and deploys everything else via GitOps.

## TLS Modes

Set `TLS_MODE` in `config/kubernetes.env`:

| Mode | Description |
|------|-------------|
| `letsencrypt` | Production Let's Encrypt certificates |
| `staging` | Let's Encrypt staging (for testing) |
| `selfsigned` | Self-signed certificates (development) |

## Manual Sync vs Auto-Sync

By default, applications are set to **manual sync** for safety.

To enable auto-sync after testing, edit `argocd/apps/app-of-apps.yaml`:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

## Updating Configuration

1. Edit the relevant values file in `argocd/helm-charts/*/values.yaml`
2. Commit and push to Git
3. ArgoCD will detect the change and show "OutOfSync"
4. Click "Sync" in ArgoCD (or auto-sync if enabled)

## Troubleshooting

**Check application status:**
```bash
kubectl get applications -n argocd
```

**View application details:**
```bash
argocd app get <app-name>
```

**Force sync:**
```bash
argocd app sync <app-name> --force
```

**Check sealed secrets:**
```bash
kubectl get sealedsecrets -A
kubectl get secrets -A | grep -E "cloudflare|grafana"
```
