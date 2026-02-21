#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}▶${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✖${NC} $1"; exit 1; }
success() { echo -e "${GREEN}✔${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Timeout for kubectl operations (seconds)
KUBECTL_TIMEOUT=10

banner() {
    echo -e "${RED}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           Proxmox-K8S Uninstall Script                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

confirm() {
    echo -e "${YELLOW}WARNING: This will remove all deployed resources!${NC}"
    echo -e "${YELLOW}The cluster itself will NOT be destroyed.${NC}"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " response
    if [[ "$response" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
}

# Helper function for non-blocking kubectl delete
kube_delete() {
    timeout ${KUBECTL_TIMEOUT} kubectl delete --wait=false "$@" 2>/dev/null || true
}

# Force remove finalizers from stuck namespace
force_delete_namespace() {
    local ns="$1"
    if kubectl get namespace "$ns" &>/dev/null; then
        log "Force removing namespace: $ns"
        kubectl get namespace "$ns" -o json 2>/dev/null | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null || true
    fi
}

# Remove finalizers from all resources in a namespace
remove_finalizers_in_namespace() {
    local ns="$1"
    
    # Remove finalizers from ArgoCD applications
    for app in $(kubectl get applications -n "$ns" -o name 2>/dev/null || true); do
        kubectl patch "$app" -n "$ns" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    done
}

delete_argocd_apps() {
    log "Removing ArgoCD Applications..."
    
    # First remove finalizers from all ArgoCD applications to prevent blocking
    for app in $(kubectl get applications -n argocd -o name 2>/dev/null || true); do
        kubectl patch "$app" -n argocd --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    done
    
    # Delete all ArgoCD Applications (non-blocking)
    kube_delete applications --all -n argocd --ignore-not-found=true
    
    success "ArgoCD Applications removed"
}

delete_helm_releases() {
    log "Removing Helm releases..."
    
    # Delete Helm releases in reverse dependency order (with timeout)
    timeout 30 helm uninstall headlamp -n headlamp --wait=false 2>/dev/null || true
    timeout 30 helm uninstall grafana -n monitoring --wait=false 2>/dev/null || true
    timeout 30 helm uninstall prometheus -n monitoring --wait=false 2>/dev/null || true
    timeout 30 helm uninstall loki -n monitoring --wait=false 2>/dev/null || true
    timeout 30 helm uninstall promtail -n monitoring --wait=false 2>/dev/null || true
    timeout 30 helm uninstall kube-state-metrics -n monitoring --wait=false 2>/dev/null || true
    timeout 30 helm uninstall node-exporter -n monitoring --wait=false 2>/dev/null || true
    timeout 30 helm uninstall traefik -n traefik --wait=false 2>/dev/null || true
    timeout 30 helm uninstall nfs-provisioner -n nfs-provisioner --wait=false 2>/dev/null || true
    timeout 30 helm uninstall metallb-config -n metallb-system --wait=false 2>/dev/null || true
    timeout 30 helm uninstall argocd -n argocd --wait=false 2>/dev/null || true
    timeout 30 helm uninstall sealed-secrets -n sealed-secrets --wait=false 2>/dev/null || true
    
    success "Helm releases removed"
}

delete_apps() {
    log "Removing applications..."
    
    # Headlamp
    kube_delete -f "${ROOT_DIR}/kubernetes/apps/headlamp/" --ignore-not-found=true
    kube_delete secret headlamp-basic-auth -n headlamp --ignore-not-found=true
    
    # ArgoCD (old style manifest install)
    kube_delete -f "${ROOT_DIR}/kubernetes/apps/argocd/" --ignore-not-found=true
    kube_delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found=true
    
    # ArgoCD IngressRoutes
    kube_delete ingressroute argocd-server -n argocd --ignore-not-found=true
    
    success "Applications removed"
}

delete_monitoring() {
    log "Removing monitoring stack..."
    
    # Grafana
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/grafana/" --ignore-not-found=true
    kube_delete secret grafana-credentials -n monitoring --ignore-not-found=true
    
    # Promtail
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/promtail/" --ignore-not-found=true
    
    # Loki
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/loki/" --ignore-not-found=true
    
    # Prometheus
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/prometheus/" --ignore-not-found=true
    
    # Kube State Metrics
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/kube-state-metrics/" --ignore-not-found=true
    
    # Node Exporter
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/node-exporter/" --ignore-not-found=true
    
    # PDBs
    kube_delete -f "${ROOT_DIR}/kubernetes/monitoring/pdb.yaml" --ignore-not-found=true
    
    success "Monitoring stack removed"
}

delete_infrastructure() {
    log "Removing infrastructure..."
    
    # Network Policies
    kube_delete -f "${ROOT_DIR}/kubernetes/infrastructure/network-policies/" --ignore-not-found=true
    
    # PDBs
    kube_delete -f "${ROOT_DIR}/kubernetes/infrastructure/pdb.yaml" --ignore-not-found=true
    
    # All IngressRoutes
    kube_delete ingressroute --all -n traefik --ignore-not-found=true
    kube_delete ingressroute --all -n monitoring --ignore-not-found=true
    kube_delete ingressroute --all -n headlamp --ignore-not-found=true
    kube_delete ingressroute --all -n argocd --ignore-not-found=true
    
    # Traefik (manifests)
    kube_delete -f "${ROOT_DIR}/kubernetes/infrastructure/traefik/deployment.yaml" --ignore-not-found=true
    kube_delete secret cloudflare-credentials -n traefik --ignore-not-found=true
    kube_delete secret traefik-default-cert -n traefik --ignore-not-found=true
    kube_delete configmap traefik-config -n traefik --ignore-not-found=true
    kube_delete tlsstore default -n traefik --ignore-not-found=true
    kube_delete middleware --all -n traefik --ignore-not-found=true
    
    # Traefik CRDs (delete after all IngressRoutes are gone)
    kube_delete -f "${ROOT_DIR}/kubernetes/infrastructure/traefik/crds.yaml" --ignore-not-found=true
    kube_delete -f https://raw.githubusercontent.com/traefik/traefik/v3.2/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml --ignore-not-found=true
    
    # ClusterRole/ClusterRoleBinding for Traefik
    kube_delete clusterrolebinding traefik-ingress-controller --ignore-not-found=true
    kube_delete clusterrole traefik-ingress-controller --ignore-not-found=true
    kube_delete clusterrolebinding traefik --ignore-not-found=true
    kube_delete clusterrole traefik --ignore-not-found=true
    
    # NFS Provisioner
    kube_delete -f "${ROOT_DIR}/kubernetes/infrastructure/nfs-provisioner/deployment.yaml" --ignore-not-found=true
    kube_delete storageclass nfs-client --ignore-not-found=true
    
    # MetalLB Config
    kube_delete -f "${ROOT_DIR}/kubernetes/infrastructure/metallb/config.yaml" --ignore-not-found=true
    kube_delete ipaddresspool --all -n metallb-system --ignore-not-found=true
    kube_delete l2advertisement --all -n metallb-system --ignore-not-found=true
    
    # MetalLB
    kube_delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml --ignore-not-found=true
    
    # Sealed Secrets
    kube_delete sealedsecret --all -A --ignore-not-found=true
    
    success "Infrastructure removed"
}

delete_namespaces() {
    log "Removing namespaces..."
    
    local namespaces="headlamp argocd monitoring traefik nfs-provisioner metallb-system sealed-secrets"
    
    # First pass: remove finalizers from stuck resources in each namespace
    for ns in $namespaces; do
        if kubectl get namespace "$ns" &>/dev/null; then
            remove_finalizers_in_namespace "$ns"
        fi
    done
    
    # Second pass: delete namespaces (non-blocking)
    for ns in $namespaces; do
        if kubectl get namespace "$ns" &>/dev/null; then
            log "Deleting namespace: $ns"
            kube_delete namespace "$ns" --ignore-not-found=true
        fi
    done
    
    # Brief wait
    sleep 3
    
    # Third pass: force delete any stuck namespaces
    for ns in $namespaces; do
        force_delete_namespace "$ns"
    done
    
    success "Namespaces removed"
}

delete_pvcs() {
    log "Removing PersistentVolumeClaims..."
    
    # Delete all PVCs in our namespaces (non-blocking)
    for ns in monitoring traefik argocd headlamp nfs-provisioner sealed-secrets; do
        kube_delete pvc --all -n "$ns" --ignore-not-found=true
    done
    
    # Clean up orphaned PVs
    for pv in $(kubectl get pv -o name 2>/dev/null || true); do
        status=$(kubectl get "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$status" == "Released" || "$status" == "Failed" ]]; then
            log "Deleting orphaned PV: $pv"
            kube_delete "$pv" --ignore-not-found=true
        fi
    done
    
    success "PVCs removed"
}

cleanup_nfs_storage() {
    log "Checking for leftover NFS storage directories..."
    
    # Load config to get NFS path
    if [[ -f "${ROOT_DIR}/config/kubernetes.env" ]]; then
        source "${ROOT_DIR}/config/kubernetes.env"
    else
        warn "Config file not found, skipping NFS cleanup"
        return 0
    fi
    
    if [[ -z "${NFS_PATH:-}" ]]; then
        warn "NFS_PATH not set, skipping NFS cleanup"
        return 0
    fi
    
    # Check if the NFS path is accessible
    if [[ ! -d "$NFS_PATH" ]]; then
        warn "NFS path $NFS_PATH not accessible from this machine"
        return 0
    fi
    
    # Find and list directories that match our PVC patterns
    local dirs_to_delete=()
    while IFS= read -r -d '' dir; do
        dirs_to_delete+=("$dir")
    done < <(find "$NFS_PATH" -maxdepth 1 -type d \( \
        -name "*-pvc-*" -o \
        -name "monitoring-*" -o \
        -name "traefik-*" -o \
        -name "argocd-*" -o \
        -name "headlamp-*" -o \
        -name "nfs-provisioner-*" \
    \) -print0 2>/dev/null)
    
    if [[ ${#dirs_to_delete[@]} -eq 0 ]]; then
        log "No leftover NFS directories found"
        return 0
    fi
    
    echo -e "\n${YELLOW}Found ${#dirs_to_delete[@]} leftover NFS directories:${NC}"
    for dir in "${dirs_to_delete[@]}"; do
        echo "  - $(basename "$dir")"
    done
    
    echo ""
    read -p "Delete these directories? (yes/no): " response
    if [[ "$response" == "yes" ]]; then
        for dir in "${dirs_to_delete[@]}"; do
            log "Deleting: $(basename "$dir")"
            rm -rf "$dir" 2>/dev/null || sudo rm -rf "$dir"
        done
        success "NFS directories cleaned up"
    else
        log "Skipping NFS cleanup"
    fi
}

cleanup_credentials() {
    log "Cleaning up credentials file..."
    
    if [[ -f "${ROOT_DIR}/config/.credentials" ]]; then
        rm -f "${ROOT_DIR}/config/.credentials"
        success "Credentials file removed"
    else
        log "No credentials file found"
    fi
}

show_status() {
    echo -e "\n${BLUE}Remaining resources:${NC}"
    echo -e "\n${BLUE}Namespaces:${NC}"
    kubectl get namespaces 2>/dev/null | grep -E "headlamp|argocd|monitoring|traefik|nfs-provisioner|metallb|sealed-secrets" || echo "  None"
    echo -e "\n${BLUE}Pods (non-system):${NC}"
    kubectl get pods -A 2>/dev/null | grep -v "kube-system" | head -10 || echo "  None"
    echo -e "\n${BLUE}Helm releases:${NC}"
    helm list -A 2>/dev/null | grep -v "NAME" || echo "  None"
}

# Main
case "${1:-all}" in
    all)
        banner
        confirm
        delete_argocd_apps
        delete_helm_releases
        delete_apps
        delete_monitoring
        delete_infrastructure
        delete_pvcs
        delete_namespaces
        cleanup_credentials
        cleanup_nfs_storage
        show_status
        echo -e "\n${GREEN}Uninstall complete!${NC}"
        ;;
    apps)
        delete_apps
        ;;
    monitoring)
        delete_monitoring
        ;;
    infra)
        delete_infrastructure
        ;;
    namespaces)
        delete_namespaces
        ;;
    credentials)
        cleanup_credentials
        ;;
    nfs)
        cleanup_nfs_storage
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [all|apps|monitoring|infra|namespaces|credentials|nfs|status]"
        echo ""
        echo "Commands:"
        echo "  all          Full uninstall (default)"
        echo "  apps         Remove applications only (ArgoCD, Headlamp)"
        echo "  monitoring   Remove monitoring stack only"
        echo "  infra        Remove infrastructure only (MetalLB, NFS, Traefik)"
        echo "  namespaces   Remove namespaces only"
        echo "  credentials  Remove credentials file only"
        echo "  nfs          Clean up leftover NFS storage directories"
        echo "  status       Show remaining resources"
        ;;
esac
