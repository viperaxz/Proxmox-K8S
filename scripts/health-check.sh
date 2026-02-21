#!/bin/bash
#
# Comprehensive Health Check Script for Proxmox-K8S Cluster
# Tests all systems, applications, and alerts on heavy load
#

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Thresholds
CPU_WARN_THRESHOLD=70
CPU_CRIT_THRESHOLD=85
MEM_WARN_THRESHOLD=75
MEM_CRIT_THRESHOLD=90
DISK_WARN_THRESHOLD=80
DISK_CRIT_THRESHOLD=90
POD_RESTART_WARN=5
POD_RESTART_CRIT=10

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARNED_CHECKS=0
FAILED_CHECKS=0

# Load credentials if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="${SCRIPT_DIR}/../config/.credentials"
if [[ -f "$CREDS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CREDS_FILE"
fi

# Logging functions
log_header() {
    echo ""
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

log_section() {
    echo ""
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

log_pass() {
    ((TOTAL_CHECKS++))
    ((PASSED_CHECKS++))
    echo -e "  ${GREEN}✓${NC} $1"
}

log_warn() {
    ((TOTAL_CHECKS++))
    ((WARNED_CHECKS++))
    echo -e "  ${YELLOW}⚠${NC} $1"
}

log_fail() {
    ((TOTAL_CHECKS++))
    ((FAILED_CHECKS++))
    echo -e "  ${RED}✗${NC} $1"
}

log_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# Check if kubectl is available
check_prerequisites() {
    log_header "Prerequisites Check"
    
    if command -v kubectl &> /dev/null; then
        log_pass "kubectl is available"
    else
        log_fail "kubectl is not installed"
        exit 1
    fi
    
    if kubectl cluster-info &> /dev/null; then
        log_pass "Cluster is reachable"
    else
        log_fail "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

# Check Certificate Signing Requests
check_csrs() {
    log_header "Certificate Signing Requests"
    
    local pending_csrs
    pending_csrs=$(kubectl get csr --no-headers 2>/dev/null | grep -c "Pending" || true)
    local total_csrs
    total_csrs=$(kubectl get csr --no-headers 2>/dev/null | wc -l)
    
    if (( pending_csrs > 0 )); then
        log_warn "Found $pending_csrs pending CSR(s) out of $total_csrs total"
        log_info "Pending CSRs may cause 'kubectl exec' and metrics collection to fail"
        log_info "To approve: kubectl get csr -o name | xargs -I {} kubectl certificate approve {}"
        
        # Show pending CSRs
        kubectl get csr --no-headers 2>/dev/null | grep "Pending" | while read -r line; do
            local csr_name requestor
            csr_name=$(echo "$line" | awk '{print $1}')
            requestor=$(echo "$line" | awk '{print $4}')
            log_info "  - $csr_name (requestor: $requestor)"
        done
    else
        if (( total_csrs > 0 )); then
            log_pass "All $total_csrs CSR(s) are approved"
        else
            log_pass "No CSRs found (cluster may be newly deployed)"
        fi
    fi
}

# Check node health
check_nodes() {
    log_header "Node Health"
    
    log_section "Node Status"
    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null)
    
    while IFS= read -r line; do
        local name status roles
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        roles=$(echo "$line" | awk '{print $3}')
        
        if [[ "$status" == "Ready" ]]; then
            log_pass "Node $name ($roles): $status"
        else
            log_fail "Node $name ($roles): $status"
        fi
    done <<< "$nodes"
    
    log_section "Node Resource Usage"
    
    # Get node metrics if metrics-server is available
    if kubectl top nodes &> /dev/null; then
        while IFS= read -r line; do
            if [[ "$line" == NAME* ]]; then continue; fi
            
            local name cpu_raw mem_raw cpu_pct mem_pct
            name=$(echo "$line" | awk '{print $1}')
            cpu_raw=$(echo "$line" | awk '{print $2}')
            cpu_pct=$(echo "$line" | awk '{print $3}' | tr -d '%')
            mem_raw=$(echo "$line" | awk '{print $4}')
            mem_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
            
            # CPU check
            if [[ -n "$cpu_pct" ]]; then
                if (( cpu_pct >= CPU_CRIT_THRESHOLD )); then
                    log_fail "Node $name CPU: ${cpu_pct}% (CRITICAL - threshold: ${CPU_CRIT_THRESHOLD}%)"
                elif (( cpu_pct >= CPU_WARN_THRESHOLD )); then
                    log_warn "Node $name CPU: ${cpu_pct}% (WARNING - threshold: ${CPU_WARN_THRESHOLD}%)"
                else
                    log_pass "Node $name CPU: ${cpu_pct}%"
                fi
            fi
            
            # Memory check
            if [[ -n "$mem_pct" ]]; then
                if (( mem_pct >= MEM_CRIT_THRESHOLD )); then
                    log_fail "Node $name Memory: ${mem_pct}% (CRITICAL - threshold: ${MEM_CRIT_THRESHOLD}%)"
                elif (( mem_pct >= MEM_WARN_THRESHOLD )); then
                    log_warn "Node $name Memory: ${mem_pct}% (WARNING - threshold: ${MEM_WARN_THRESHOLD}%)"
                else
                    log_pass "Node $name Memory: ${mem_pct}%"
                fi
            fi
        done < <(kubectl top nodes 2>/dev/null)
    else
        log_info "Metrics server not available - skipping resource usage checks"
    fi
    
    # Check node conditions
    log_section "Node Conditions"
    local node_issues
    node_issues=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}{"\n"}{end}' 2>/dev/null)
    
    while IFS=$'\t' read -r name conditions; do
        if [[ "$conditions" == *"MemoryPressure"* ]]; then
            log_fail "Node $name: MemoryPressure detected"
        fi
        if [[ "$conditions" == *"DiskPressure"* ]]; then
            log_fail "Node $name: DiskPressure detected"
        fi
        if [[ "$conditions" == *"PIDPressure"* ]]; then
            log_fail "Node $name: PIDPressure detected"
        fi
        if [[ "$conditions" == *"NetworkUnavailable"* ]]; then
            log_fail "Node $name: NetworkUnavailable"
        fi
        if [[ "$conditions" == "Ready " ]] || [[ "$conditions" == "Ready" ]]; then
            log_pass "Node $name: No pressure conditions"
        fi
    done <<< "$node_issues"
}

# Check pod health
check_pods() {
    log_header "Pod Health"
    
    log_section "Pod Status by Namespace"
    
    local namespaces
    namespaces=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -v "^kube-")
    
    for ns in $namespaces; do
        local total running pending failed
        total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || true)
        pending=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Pending" || true)
        failed=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -cE "Error|CrashLoopBackOff|ImagePullBackOff|Failed" || true)
        
        if (( failed > 0 )); then
            log_fail "Namespace $ns: $running/$total Running, $failed Failed/Error"
        elif (( pending > 0 )); then
            log_warn "Namespace $ns: $running/$total Running, $pending Pending"
        elif (( total > 0 )); then
            log_pass "Namespace $ns: $running/$total Running"
        fi
    done
    
    log_section "Pods with High Restart Count"
    local restart_issues=0
    
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local ns name restarts
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        restarts=$(echo "$line" | awk '{print $4}')
        
        # Handle restarts like "5 (2h ago)"
        restarts=${restarts%%[[:space:]]*}
        restarts=${restarts%%(*}
        
        if [[ "$restarts" =~ ^[0-9]+$ ]]; then
            if (( restarts >= POD_RESTART_CRIT )); then
                log_fail "Pod $ns/$name: $restarts restarts (CRITICAL)"
                ((restart_issues++))
            elif (( restarts >= POD_RESTART_WARN )); then
                log_warn "Pod $ns/$name: $restarts restarts (WARNING)"
                ((restart_issues++))
            fi
        fi
    done < <(kubectl get pods -A --no-headers 2>/dev/null | grep -v "^kube-")
    
    if (( restart_issues == 0 )); then
        log_pass "No pods with excessive restarts"
    fi
    
    log_section "Pods Not Ready"
    local not_ready
    # Check for pods where READY column doesn't show all containers ready (e.g., 0/1 or 1/2)
    not_ready=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v "^kube-" | awk '
        $4 == "Running" {
            split($3, a, "/")
            if (a[1] != a[2]) print $1"/"$2": "$3
        }
    ' || true)
    
    if [[ -n "$not_ready" ]]; then
        while IFS= read -r pod; do
            log_warn "Pod not fully ready: $pod"
        done <<< "$not_ready"
    else
        log_pass "All running pods are fully ready"
    fi
}

# Check ArgoCD applications
check_argocd() {
    log_header "ArgoCD Applications"
    
    if ! kubectl get ns argocd &> /dev/null; then
        log_warn "ArgoCD namespace not found - skipping"
        return
    fi
    
    log_section "Application Sync Status"
    
    local apps
    apps=$(kubectl get applications -n argocd --no-headers 2>/dev/null || true)
    
    if [[ -z "$apps" ]]; then
        log_warn "No ArgoCD applications found"
        return
    fi
    
    local synced=0 outofsync=0 healthy=0 degraded=0
    
    while IFS= read -r line; do
        local name sync_status health_status
        name=$(echo "$line" | awk '{print $1}')
        sync_status=$(echo "$line" | awk '{print $2}')
        health_status=$(echo "$line" | awk '{print $3}')
        
        # Track stats
        [[ "$sync_status" == "Synced" ]] && ((synced++))
        [[ "$sync_status" == "OutOfSync" ]] && ((outofsync++))
        [[ "$health_status" == "Healthy" ]] && ((healthy++))
        [[ "$health_status" == "Degraded" ]] && ((degraded++))
        
        # Log status
        if [[ "$health_status" == "Degraded" ]]; then
            log_fail "App $name: $sync_status / $health_status"
        elif [[ "$sync_status" == "OutOfSync" && "$name" != "argocd" ]]; then
            log_warn "App $name: $sync_status / $health_status"
        elif [[ "$sync_status" == "OutOfSync" && "$name" == "argocd" ]]; then
            # Self-managed ArgoCD is expected to show OutOfSync
            log_pass "App $name: $sync_status / $health_status (expected for self-managed)"
        else
            log_pass "App $name: $sync_status / $health_status"
        fi
    done <<< "$apps"
    
    log_section "ArgoCD Summary"
    log_info "Total Applications: $((synced + outofsync))"
    log_info "Synced: $synced, OutOfSync: $outofsync"
    log_info "Healthy: $healthy, Degraded: $degraded"
}

# Check services and endpoints
check_services() {
    log_header "Services & Networking"
    
    log_section "LoadBalancer Services"
    local lb_services
    lb_services=$(kubectl get svc -A --no-headers 2>/dev/null | grep LoadBalancer || true)
    
    if [[ -n "$lb_services" ]]; then
        while IFS= read -r line; do
            local ns name external_ip
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
            external_ip=$(echo "$line" | awk '{print $5}')
            
            if [[ "$external_ip" == "<pending>" ]] || [[ -z "$external_ip" ]]; then
                log_fail "Service $ns/$name: No external IP assigned"
            else
                log_pass "Service $ns/$name: $external_ip"
            fi
        done <<< "$lb_services"
    else
        log_warn "No LoadBalancer services found"
    fi
    
    log_section "Endpoint Health"
    local endpoints_missing
    endpoints_missing=$(kubectl get endpoints -A --no-headers 2>/dev/null | awk '$2 == "<none>" || $2 == "" {print $1"/"$1}' | head -10 || true)
    
    if [[ -n "$endpoints_missing" ]]; then
        while IFS= read -r ep; do
            log_warn "Service with no endpoints: $ep"
        done <<< "$endpoints_missing"
    else
        log_pass "All services have endpoints"
    fi
}

# Check storage
check_storage() {
    log_header "Storage"
    
    log_section "Persistent Volume Claims"
    local pvcs
    pvcs=$(kubectl get pvc -A --no-headers 2>/dev/null || true)
    
    if [[ -z "$pvcs" ]]; then
        log_info "No PVCs found"
        return
    fi
    
    local bound=0 pending=0
    
    while IFS= read -r line; do
        local ns name status
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')
        
        if [[ "$status" == "Bound" ]]; then
            log_pass "PVC $ns/$name: $status"
            ((bound++))
        else
            log_fail "PVC $ns/$name: $status"
            ((pending++))
        fi
    done <<< "$pvcs"
    
    log_section "StorageClass"
    local default_sc
    default_sc=$(kubectl get sc --no-headers 2>/dev/null | grep "(default)" || true)
    
    if [[ -n "$default_sc" ]]; then
        local sc_name
        sc_name=$(echo "$default_sc" | awk '{print $1}')
        log_pass "Default StorageClass: $sc_name"
    else
        log_warn "No default StorageClass configured"
    fi
}

# Check monitoring stack
check_monitoring() {
    log_header "Monitoring Stack"
    
    if ! kubectl get ns monitoring &> /dev/null; then
        log_warn "Monitoring namespace not found - skipping"
        return
    fi
    
    log_section "Prometheus"
    local prom_pod
    prom_pod=$(kubectl get pods -n monitoring -l app=prometheus --no-headers 2>/dev/null | head -1)
    
    if [[ -n "$prom_pod" ]]; then
        local status ready
        status=$(echo "$prom_pod" | awk '{print $3}')
        ready=$(echo "$prom_pod" | awk '{print $2}')
        
        if [[ "$status" == "Running" ]] && [[ "$ready" == "1/1" ]]; then
            log_pass "Prometheus pod: Running and Ready"
            
            # Check targets via curl/wget
            local targets_response targets_up targets_down
            targets_response=$(kubectl exec -n monitoring deploy/prometheus -- wget -qO- "http://localhost:9090/api/v1/targets" 2>/dev/null || true)
            
            if [[ -n "$targets_response" ]]; then
                targets_up=$(echo "$targets_response" | grep -o '"health":"up"' | wc -l)
                targets_down=$(echo "$targets_response" | grep -o '"health":"down"' | wc -l)
                
                # Ensure numeric values
                targets_up=${targets_up:-0}
                targets_down=${targets_down:-0}
                
                if [[ "$targets_down" -gt 0 ]]; then
                    log_warn "Prometheus targets: $targets_up up, $targets_down down"
                else
                    log_pass "Prometheus targets: $targets_up up"
                fi
            else
                log_info "Could not query Prometheus targets API"
            fi
        else
            log_fail "Prometheus pod: $status ($ready)"
        fi
    else
        log_fail "Prometheus pod not found"
    fi
    
    log_section "Grafana"
    local grafana_pod
    grafana_pod=$(kubectl get pods -n monitoring -l app=grafana --no-headers 2>/dev/null | head -1)
    
    if [[ -n "$grafana_pod" ]]; then
        local status ready
        status=$(echo "$grafana_pod" | awk '{print $3}')
        ready=$(echo "$grafana_pod" | awk '{print $2}')
        
        if [[ "$status" == "Running" ]] && [[ "$ready" == "1/1" ]]; then
            log_pass "Grafana pod: Running and Ready"
        else
            log_fail "Grafana pod: $status ($ready)"
        fi
    else
        log_fail "Grafana pod not found"
    fi
    
    log_section "Loki"
    local loki_pod
    loki_pod=$(kubectl get pods -n monitoring -l app=loki --no-headers 2>/dev/null | head -1)
    
    if [[ -n "$loki_pod" ]]; then
        local status ready
        status=$(echo "$loki_pod" | awk '{print $3}')
        ready=$(echo "$loki_pod" | awk '{print $2}')
        
        if [[ "$status" == "Running" ]] && [[ "$ready" == "1/1" ]]; then
            log_pass "Loki pod: Running and Ready"
        else
            log_fail "Loki pod: $status ($ready)"
        fi
    else
        log_fail "Loki pod not found"
    fi
    
    log_section "Promtail DaemonSet"
    local promtail_ds
    promtail_ds=$(kubectl get ds promtail -n monitoring --no-headers 2>/dev/null || true)
    
    if [[ -n "$promtail_ds" ]]; then
        local desired ready
        desired=$(echo "$promtail_ds" | awk '{print $2}')
        ready=$(echo "$promtail_ds" | awk '{print $4}')
        
        if [[ "$desired" == "$ready" ]]; then
            log_pass "Promtail DaemonSet: $ready/$desired ready"
        else
            log_warn "Promtail DaemonSet: $ready/$desired ready"
        fi
    else
        log_fail "Promtail DaemonSet not found"
    fi
    
    log_section "Node Exporter DaemonSet"
    local node_exporter_ds
    node_exporter_ds=$(kubectl get ds node-exporter -n monitoring --no-headers 2>/dev/null || true)
    
    if [[ -n "$node_exporter_ds" ]]; then
        local desired ready
        desired=$(echo "$node_exporter_ds" | awk '{print $2}')
        ready=$(echo "$node_exporter_ds" | awk '{print $4}')
        
        if [[ "$desired" == "$ready" ]]; then
            log_pass "Node Exporter DaemonSet: $ready/$desired ready"
        else
            log_warn "Node Exporter DaemonSet: $ready/$desired ready"
        fi
    else
        log_fail "Node Exporter DaemonSet not found"
    fi
}

# Check web endpoints accessibility
check_web_endpoints() {
    log_header "Web Endpoints Accessibility"
    
    # Get Traefik IP
    local traefik_ip
    traefik_ip=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    
    if [[ -z "$traefik_ip" ]]; then
        log_warn "Traefik LoadBalancer IP not found - skipping endpoint checks"
        return
    fi
    
    log_info "Using Traefik IP: $traefik_ip"
    
    local endpoints=("argocd" "grafana" "headlamp" "prometheus" "traefik")
    local domain="${DOMAIN:-viperax.org}"
    
    for endpoint in "${endpoints[@]}"; do
        local url="https://${endpoint}.${domain}"
        local response
        
        # Use curl with host header to test through Traefik
        response=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
            --resolve "${endpoint}.${domain}:443:${traefik_ip}" \
            "$url" 2>/dev/null || echo "000")
        
        if [[ "$response" == "200" ]] || [[ "$response" == "302" ]] || [[ "$response" == "303" ]]; then
            log_pass "$url: HTTP $response"
        elif [[ "$response" == "401" ]] || [[ "$response" == "403" ]]; then
            log_pass "$url: HTTP $response (auth required - expected)"
        elif [[ "$response" == "000" ]]; then
            log_fail "$url: Connection failed"
        else
            log_warn "$url: HTTP $response"
        fi
    done
}

# Check resource quotas and limits
check_resource_usage() {
    log_header "Resource Usage Analysis"
    
    if ! kubectl top pods -A &> /dev/null; then
        log_warn "Metrics not available - skipping detailed resource analysis"
        return
    fi
    
    log_section "Top CPU Consuming Pods"
    local top_cpu
    top_cpu=$(kubectl top pods -A --no-headers 2>/dev/null | sort -k3 -h -r | head -5)
    
    while IFS= read -r line; do
        local ns name cpu mem
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        cpu=$(echo "$line" | awk '{print $3}')
        mem=$(echo "$line" | awk '{print $4}')
        log_info "CPU: $cpu | MEM: $mem | $ns/$name"
    done <<< "$top_cpu"
    
    log_section "Top Memory Consuming Pods"
    local top_mem
    top_mem=$(kubectl top pods -A --no-headers 2>/dev/null | sort -k4 -h -r | head -5)
    
    while IFS= read -r line; do
        local ns name cpu mem
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        cpu=$(echo "$line" | awk '{print $3}')
        mem=$(echo "$line" | awk '{print $4}')
        log_info "MEM: $mem | CPU: $cpu | $ns/$name"
    done <<< "$top_mem"
    
    log_section "Cluster Resource Summary"
    local total_cpu_req total_cpu_lim total_mem_req total_mem_lim
    
    # Calculate total requests and limits
    total_cpu_req=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}{end}' 2>/dev/null | \
        awk '{sum += ($0 ~ /m$/) ? $0+0 : $0*1000} END {printf "%.0f", sum}' || echo "0")
    total_mem_req=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.memory}{"\n"}{end}{end}' 2>/dev/null | \
        awk '{sum += ($0 ~ /Mi$/) ? $0+0 : ($0 ~ /Gi$/) ? $0*1024 : $0/1048576} END {printf "%.0f", sum}' || echo "0")
    
    log_info "Total CPU Requested: ${total_cpu_req}m"
    log_info "Total Memory Requested: ${total_mem_req}Mi"
}

# Check for common issues
check_common_issues() {
    log_header "Common Issues Detection"
    
    log_section "ImagePullBackOff / ErrImagePull"
    local image_issues
    image_issues=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E "ImagePullBackOff|ErrImagePull" || true)
    
    if [[ -n "$image_issues" ]]; then
        while IFS= read -r line; do
            local ns name
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
            log_fail "Image pull issue: $ns/$name"
        done <<< "$image_issues"
    else
        log_pass "No image pull issues"
    fi
    
    log_section "CrashLoopBackOff"
    local crash_issues
    crash_issues=$(kubectl get pods -A --no-headers 2>/dev/null | grep "CrashLoopBackOff" || true)
    
    if [[ -n "$crash_issues" ]]; then
        while IFS= read -r line; do
            local ns name
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
            log_fail "CrashLoopBackOff: $ns/$name"
        done <<< "$crash_issues"
    else
        log_pass "No CrashLoopBackOff pods"
    fi
    
    log_section "Evicted Pods"
    local evicted
    evicted=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Evicted" || true)
    
    if [[ -n "$evicted" ]]; then
        local count
        count=$(echo "$evicted" | wc -l)
        log_warn "$count evicted pods found (consider cleanup)"
    else
        log_pass "No evicted pods"
    fi
    
    log_section "Pending Pods"
    local pending_pods
    pending_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Pending" || true)
    
    if [[ -n "$pending_pods" ]]; then
        while IFS= read -r line; do
            local ns name
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
            log_warn "Pending pod: $ns/$name"
        done <<< "$pending_pods"
    else
        log_pass "No pending pods"
    fi
    
    log_section "Recent Events (Warnings)"
    local warning_events
    warning_events=$(kubectl get events -A --field-selector type=Warning --no-headers 2>/dev/null | tail -5 || true)
    
    if [[ -n "$warning_events" ]]; then
        log_warn "Recent warning events detected:"
        while IFS= read -r line; do
            local ns reason msg
            ns=$(echo "$line" | awk '{print $1}')
            reason=$(echo "$line" | awk '{print $4}')
            msg=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=""; print $0}' | xargs)
            log_info "  [$ns] $reason: ${msg:0:60}..."
        done <<< "$warning_events"
    else
        log_pass "No recent warning events"
    fi
}

# Check sealed secrets
check_sealed_secrets() {
    log_header "Sealed Secrets"
    
    if ! kubectl get ns sealed-secrets &> /dev/null; then
        log_warn "Sealed Secrets namespace not found - skipping"
        return
    fi
    
    local ss_pod
    ss_pod=$(kubectl get pods -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets --no-headers 2>/dev/null | head -1)
    
    if [[ -n "$ss_pod" ]]; then
        local status
        status=$(echo "$ss_pod" | awk '{print $3}')
        
        if [[ "$status" == "Running" ]]; then
            log_pass "Sealed Secrets controller: Running"
        else
            log_fail "Sealed Secrets controller: $status"
        fi
    else
        log_fail "Sealed Secrets controller not found"
    fi
}

# Print summary
print_summary() {
    log_header "Health Check Summary"
    
    echo ""
    echo -e "  ${BOLD}Total Checks:${NC}  $TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed:${NC}        $PASSED_CHECKS"
    echo -e "  ${YELLOW}Warnings:${NC}      $WARNED_CHECKS"
    echo -e "  ${RED}Failed:${NC}        $FAILED_CHECKS"
    echo ""
    
    local health_pct
    if (( TOTAL_CHECKS > 0 )); then
        health_pct=$(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))
    else
        health_pct=0
    fi
    
    echo -e "  ${BOLD}Overall Health:${NC} ${health_pct}%"
    echo ""
    
    if (( FAILED_CHECKS > 0 )); then
        echo -e "  ${RED}${BOLD}⚠ ATTENTION: $FAILED_CHECKS critical issues require attention!${NC}"
        echo ""
        exit 1
    elif (( WARNED_CHECKS > 0 )); then
        echo -e "  ${YELLOW}${BOLD}ℹ INFO: $WARNED_CHECKS warnings detected - review recommended${NC}"
        echo ""
        exit 0
    else
        echo -e "  ${GREEN}${BOLD}✓ All systems operational!${NC}"
        echo ""
        exit 0
    fi
}

# Main execution
main() {
    echo ""
    echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║       Proxmox-K8S Comprehensive Health Check                      ║${NC}"
    echo -e "${BOLD}${GREEN}║       $(date '+%Y-%m-%d %H:%M:%S')                                       ║${NC}"
    echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    
    check_prerequisites
    check_csrs
    check_nodes
    check_pods
    check_argocd
    check_services
    check_storage
    check_monitoring
    check_sealed_secrets
    check_web_endpoints
    check_resource_usage
    check_common_issues
    print_summary
}

# Run with optional flags
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -h, --help     Show this help message"
        echo "  -q, --quick    Run quick check (skip endpoint tests)"
        echo "  -v, --verbose  Show more detailed output"
        echo ""
        echo "Thresholds (can be modified in script):"
        echo "  CPU Warning: ${CPU_WARN_THRESHOLD}%  Critical: ${CPU_CRIT_THRESHOLD}%"
        echo "  Memory Warning: ${MEM_WARN_THRESHOLD}%  Critical: ${MEM_CRIT_THRESHOLD}%"
        echo "  Pod Restart Warning: ${POD_RESTART_WARN}  Critical: ${POD_RESTART_CRIT}"
        exit 0
        ;;
    -q|--quick)
        check_prerequisites
        check_csrs
        check_nodes
        check_pods
        check_argocd
        check_common_issues
        print_summary
        ;;
    *)
        main
        ;;
esac
