#!/bin/bash
set -euo pipefail

# =============================================================================
# Minimal Bootstrap Script for ArgoCD GitOps
# =============================================================================
# This script only installs the bare minimum required for ArgoCD to take over:
# 1. Namespaces
# 2. Sealed Secrets controller
# 3. ArgoCD
# 4. Initial sealed secrets (Cloudflare, Grafana credentials)
# 5. App of Apps (triggers ArgoCD to deploy everything else)
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/kubernetes.env"
CREDENTIALS_FILE="${ROOT_DIR}/config/.credentials"

log() { echo -e "${GREEN}▶${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✖${NC} $1"; exit 1; }
success() { echo -e "${GREEN}✔${NC} $1"; }

banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        Proxmox-K8S ArgoCD Bootstrap Script                 ║"
    echo "║            GitOps-based Deployment                         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

generate_secret() {
    openssl rand -base64 32 | tr -d '=/+' | head -c 32
}

check_prereqs() {
    log "Checking prerequisites..."
    
    local missing=()
    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v helm &>/dev/null || missing+=("helm")
    command -v kubeseal &>/dev/null || missing+=("kubeseal")
    command -v openssl &>/dev/null || missing+=("openssl")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to cluster. Check KUBECONFIG."
    fi
    
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "$node_count" -lt 1 ]]; then
        error "No nodes found in cluster"
    fi
    
    success "Prerequisites OK ($node_count nodes found)"
}

load_config() {
    log "Loading configuration..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cp "${ROOT_DIR}/config/kubernetes.env.example" "$CONFIG_FILE" 2>/dev/null || true
        error "Config not found. Edit ${CONFIG_FILE} first."
    fi
    
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    
    TLS_MODE="${TLS_MODE:-staging}"
    
    case "$TLS_MODE" in
        letsencrypt)
            CERT_RESOLVER="letsencrypt"
            log "TLS Mode: $TLS_MODE (production certificates)"
            ;;
        staging)
            CERT_RESOLVER="letsencrypt-staging"
            log "TLS Mode: $TLS_MODE (staging certificates)"
            ;;
        selfsigned)
            CERT_RESOLVER=""
            log "TLS Mode: $TLS_MODE (self-signed certificates)"
            ;;
        *)
            error "Invalid TLS_MODE: $TLS_MODE"
            ;;
    esac
    
    export DOMAIN METALLB_IP_RANGE NFS_SERVER NFS_PATH TLS_MODE CERT_RESOLVER
    
    for var in DOMAIN METALLB_IP_RANGE NFS_SERVER NFS_PATH; do
        [[ -z "${!var:-}" ]] && error "Missing: $var"
    done
    
    if [[ "$TLS_MODE" != "selfsigned" ]]; then
        for var in CLOUDFLARE_EMAIL CLOUDFLARE_API_TOKEN; do
            [[ -z "${!var:-}" ]] && error "Missing: $var (required for $TLS_MODE mode)"
        done
    fi
    
    success "Configuration loaded"
}

deploy_namespaces() {
    log "Creating namespaces..."
    kubectl apply -f "${ROOT_DIR}/kubernetes/namespaces.yaml"
    
    # Create sealed-secrets namespace
    kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
    
    success "Namespaces created"
}

deploy_sealed_secrets() {
    log "Installing Sealed Secrets controller..."
    
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
    helm repo update
    
    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace sealed-secrets \
        --set fullnameOverride=sealed-secrets-controller \
        --wait
    
    # Wait for controller to be ready
    kubectl wait --for=condition=available deployment/sealed-secrets-controller \
        -n sealed-secrets --timeout=120s
    
    # Wait a bit for the service endpoints to be ready
    sleep 5
    
    success "Sealed Secrets controller installed"
}

create_sealed_secrets() {
    log "Creating sealed secrets..."
    
    # Create secrets directory if it doesn't exist
    mkdir -p "${ROOT_DIR}/argocd/sealed-secrets"
    
    # Cloudflare credentials (only for letsencrypt/staging modes)
    if [[ "$TLS_MODE" != "selfsigned" ]]; then
        log "Creating Cloudflare sealed secret..."
        kubectl create secret generic cloudflare-credentials \
            --namespace traefik \
            --from-literal=CF_API_EMAIL="${CLOUDFLARE_EMAIL}" \
            --from-literal=CF_DNS_API_TOKEN="${CLOUDFLARE_API_TOKEN}" \
            --dry-run=client -o yaml | \
            kubeseal --controller-name=sealed-secrets-controller \
                     --controller-namespace=sealed-secrets \
                     --format yaml > "${ROOT_DIR}/argocd/sealed-secrets/cloudflare-credentials.yaml"
        
        kubectl apply -f "${ROOT_DIR}/argocd/sealed-secrets/cloudflare-credentials.yaml"
        success "Cloudflare sealed secret created"
    fi
    
    # Grafana credentials
    log "Creating Grafana sealed secret..."
    GRAFANA_ADMIN_PASSWORD=$(generate_secret)
    kubectl create secret generic grafana-credentials \
        --namespace monitoring \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
        --dry-run=client -o yaml | \
        kubeseal --controller-name=sealed-secrets-controller \
                 --controller-namespace=sealed-secrets \
                 --format yaml > "${ROOT_DIR}/argocd/sealed-secrets/grafana-credentials.yaml"
    
    kubectl apply -f "${ROOT_DIR}/argocd/sealed-secrets/grafana-credentials.yaml"
    success "Grafana sealed secret created"
    
    # Store password for reference
    echo "GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}" > "${CREDENTIALS_FILE}.tmp"
}

deploy_argocd() {
    log "Installing ArgoCD..."
    
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update
    
    # Install ArgoCD with our values
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --values "${ROOT_DIR}/argocd/helm-values/argocd.yaml" \
        --set "configs.cm.url=https://argocd.${DOMAIN}" \
        --set "global.domain=argocd.${DOMAIN}" \
        --wait
    
    kubectl wait --for=condition=available deployment/argocd-server \
        -n argocd --timeout=300s
    
    success "ArgoCD installed"
}

install_traefik_crds() {
    log "Installing Traefik CRDs..."
    
    # Install Traefik CRDs so we can create IngressRoutes
    kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.2/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
    
    success "Traefik CRDs installed"
}

deploy_argocd_ingress() {
    log "Creating ArgoCD ingress..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`argocd.${DOMAIN}\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls: {}
EOF
    
    success "ArgoCD ingress created"
}

update_argocd_values() {
    log "Updating ArgoCD helm values with current configuration..."
    
    # Update the central values.yaml with current config
    cat > "${ROOT_DIR}/argocd/values.yaml" <<EOF
# Central configuration for all ArgoCD-managed applications
# Generated by bootstrap.sh on $(date)

# Git repository settings
git:
  repoURL: https://github.com/viperaxz/Proxmox-K8S.git
  targetRevision: main
  
# Cluster settings
cluster:
  domain: ${DOMAIN}
  
# MetalLB settings
metallb:
  ipRange: "${METALLB_IP_RANGE}"

# NFS Provisioner settings
nfs:
  server: "${NFS_SERVER}"
  path: "${NFS_PATH}"

# TLS settings
tls:
  mode: ${TLS_MODE}
  certResolver: ${CERT_RESOLVER:-""}
  cloudflare:
    email: "${CLOUDFLARE_EMAIL:-}"

# Traefik settings
traefik:
  replicas: 1
  dashboard:
    enabled: true

# Monitoring settings
monitoring:
  prometheus:
    retention: 15d
    storageSize: 20Gi
  grafana:
    storageSize: 5Gi
  loki:
    retention: 168h
    storageSize: 20Gi

# ArgoCD settings
argocd:
  syncPolicy: manual
EOF
    
    success "ArgoCD values updated"
}

update_helm_values() {
    log "Updating individual Helm chart values..."
    
    # Update NFS provisioner values
    cat > "${ROOT_DIR}/argocd/helm-charts/nfs-provisioner/values.yaml" <<EOF
nfs:
  server: "${NFS_SERVER}"
  path: "${NFS_PATH}"

storageClass:
  name: nfs-client
  isDefault: true
  archiveOnDelete: false
  reclaimPolicy: Delete

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
EOF

    # Update MetalLB config values
    cat > "${ROOT_DIR}/argocd/helm-charts/metallb-config/values.yaml" <<EOF
metallb:
  ipRange: "${METALLB_IP_RANGE}"
EOF

    # Update Prometheus values
    cat > "${ROOT_DIR}/argocd/helm-charts/prometheus/values.yaml" <<EOF
cluster:
  domain: "${DOMAIN}"

tls:
  mode: ${TLS_MODE}
  certResolver: ${CERT_RESOLVER:-""}

prometheus:
  image: prom/prometheus:v2.54.1
  retention: 15d
  storage:
    size: 20Gi
    storageClass: nfs-client
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi

ingress:
  enabled: true
EOF

    # Update Grafana values
    cat > "${ROOT_DIR}/argocd/helm-charts/grafana/values.yaml" <<EOF
cluster:
  domain: "${DOMAIN}"

tls:
  mode: ${TLS_MODE}
  certResolver: ${CERT_RESOLVER:-""}

grafana:
  image: grafana/grafana:11.4.0
  plugins: "grafana-clock-panel,grafana-piechart-panel"
  storage:
    size: 5Gi
    storageClass: nfs-client
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

credentials:
  secretName: grafana-credentials

ingress:
  enabled: true
EOF

    # Update Headlamp values
    cat > "${ROOT_DIR}/argocd/helm-charts/headlamp/values.yaml" <<EOF
cluster:
  domain: "${DOMAIN}"

tls:
  mode: ${TLS_MODE}
  certResolver: ${CERT_RESOLVER:-""}

headlamp:
  image: ghcr.io/headlamp-k8s/headlamp:v0.25.0
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

ingress:
  enabled: true
EOF

    success "Helm values updated"
}

deploy_app_of_apps() {
    log "Deploying App of Apps..."
    
    kubectl apply -f "${ROOT_DIR}/argocd/apps/app-of-apps.yaml"
    
    success "App of Apps deployed - ArgoCD will now manage all applications!"
}

generate_selfsigned_cert() {
    if [[ "$TLS_MODE" == "selfsigned" ]]; then
        log "Generating self-signed certificate..."
        
        # Ensure traefik namespace exists
        kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /tmp/tls.key \
            -out /tmp/tls.crt \
            -subj "/CN=*.${DOMAIN}" \
            -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}" 2>/dev/null
        
        kubectl create secret tls traefik-default-cert \
            --namespace traefik \
            --cert=/tmp/tls.crt \
            --key=/tmp/tls.key \
            --dry-run=client -o yaml | kubectl apply -f -
        
        rm -f /tmp/tls.key /tmp/tls.crt
        success "Self-signed certificate created"
    fi
}

show_summary() {
    # Get ArgoCD admin password
    ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d) || ARGOCD_ADMIN_PASSWORD="<pending>"
    
    # Get Grafana password from temp file
    GRAFANA_ADMIN_PASSWORD=""
    if [[ -f "${CREDENTIALS_FILE}.tmp" ]]; then
        # shellcheck source=/dev/null
        source "${CREDENTIALS_FILE}.tmp"
        rm -f "${CREDENTIALS_FILE}.tmp"
    fi
    
    # Generate Headlamp service account token (24h)
    log "Generating Headlamp access token (24h)..."
    
    # Wait for headlamp service account to exist
    local max_wait=60
    local waited=0
    while ! kubectl get sa headlamp-admin -n headlamp &>/dev/null; do
        if [[ $waited -ge $max_wait ]]; then
            warn "Headlamp service account not ready yet. Token will be generated later."
            HEADLAMP_TOKEN="<pending - run: kubectl create token headlamp-admin -n headlamp --duration=24h>"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    if [[ -z "${HEADLAMP_TOKEN:-}" ]]; then
        HEADLAMP_TOKEN=$(kubectl create token headlamp-admin -n headlamp --duration=24h 2>/dev/null) || \
            HEADLAMP_TOKEN="<pending - run: kubectl create token headlamp-admin -n headlamp --duration=24h>"
    fi
    
    # Save credentials
    cat > "$CREDENTIALS_FILE" <<EOF
# Credentials generated by bootstrap.sh (GitOps)
# Generated: $(date)

# ArgoCD
ARGOCD_URL="https://argocd.${DOMAIN}"
ARGOCD_ADMIN_USER="admin"
ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD}"

# Grafana
GRAFANA_URL="https://grafana.${DOMAIN}"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"

# Headlamp (token valid for 24h - regenerate with: kubectl create token headlamp-admin -n headlamp --duration=24h)
HEADLAMP_URL="https://headlamp.${DOMAIN}"
HEADLAMP_TOKEN="${HEADLAMP_TOKEN}"

# Other URLs
PROMETHEUS_URL="https://prometheus.${DOMAIN}"
TRAEFIK_URL="https://traefik.${DOMAIN}"

# Configuration
TLS_MODE="${TLS_MODE}"
DOMAIN="${DOMAIN}"
EOF

    echo -e "\n${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                   BOOTSTRAP COMPLETE!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${BLUE}What was installed:${NC}"
    echo "  ✔ Namespaces"
    echo "  ✔ Sealed Secrets controller"
    echo "  ✔ ArgoCD"
    echo "  ✔ Sealed secrets (Cloudflare, Grafana)"
    echo "  ✔ App of Apps"
    
    echo -e "\n${BLUE}ArgoCD will now deploy:${NC}"
    echo "  • MetalLB"
    echo "  • NFS Provisioner"
    echo "  • Traefik"
    echo "  • Prometheus, Grafana, Loki, Promtail"
    echo "  • Headlamp"
    echo "  • Network Policies"
    echo "  • PodDisruptionBudgets"
    
    echo -e "\n${BLUE}TLS Mode:${NC} ${TLS_MODE}"
    
    echo -e "\n${BLUE}Access:${NC}"
    echo "  ArgoCD:     https://argocd.${DOMAIN}  (admin / ${ARGOCD_ADMIN_PASSWORD})"
    echo "  Grafana:    https://grafana.${DOMAIN}  (admin / ${GRAFANA_ADMIN_PASSWORD})"
    echo "  Headlamp:   https://headlamp.${DOMAIN}  (use token from credentials file)"
    echo "  Prometheus: https://prometheus.${DOMAIN}"
    echo "  Traefik:    https://traefik.${DOMAIN}"
    
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo "  1. Configure DNS: *.${DOMAIN} → <Traefik LoadBalancer IP>"
    echo "  2. Open ArgoCD and sync all applications"
    echo "  3. Once stable, enable auto-sync in app-of-apps.yaml"
    
    echo -e "\n${YELLOW}Credentials saved to: ${CREDENTIALS_FILE}${NC}"
    
    echo -e "\n${BLUE}Monitor deployments:${NC}"
    echo "  kubectl get applications -n argocd"
    echo "  argocd app list"
}

show_status() {
    log "ArgoCD Application Status:"
    kubectl get applications -n argocd 2>/dev/null || echo "No applications found"
    echo ""
    log "Pods:"
    kubectl get pods -A | grep -E "sealed-secrets|argocd" || echo "None found"
}

# Main
case "${1:-all}" in
    all)
        banner
        check_prereqs
        load_config
        deploy_namespaces
        deploy_sealed_secrets
        create_sealed_secrets
        generate_selfsigned_cert
        deploy_argocd
        install_traefik_crds
        update_argocd_values
        update_helm_values
        deploy_argocd_ingress
        deploy_app_of_apps
        show_summary
        ;;
    status)
        show_status
        ;;
    secrets)
        check_prereqs
        load_config
        create_sealed_secrets
        ;;
    *)
        echo "Usage: $0 [all|status|secrets]"
        echo ""
        echo "Commands:"
        echo "  all       Full bootstrap (default)"
        echo "  status    Show ArgoCD application status"
        echo "  secrets   Regenerate sealed secrets only"
        ;;
esac
