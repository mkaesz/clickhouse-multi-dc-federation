#!/usr/bin/env bash
# Full POC setup: kind cluster + external Keepers + ClickHouse (Helm) for FRA/MUC/HAM.
# Run from the repo root:  bash poc/setup.sh
#
# Prerequisites: kind, kubectl, helm, docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/manifests"
HELM_VALUES="$SCRIPT_DIR/helm"

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

check_prereqs() {
    log "Checking prerequisites"
    local missing=()
    for cmd in kind kubectl helm docker; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        else
            info "$cmd: $(${cmd} version --short 2>/dev/null || ${cmd} version 2>/dev/null | head -1)"
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: missing required tools: ${missing[*]}"
        exit 1
    fi
}

wait_for_pods() {
    bash "$SCRIPT_DIR/scripts/wait-for-pods.sh" "$@"
}

# ── Step 1: kind cluster ───────────────────────────────────────────────────────

create_cluster() {
    log "Creating kind cluster 'geo-poc'"
    if kind get clusters 2>/dev/null | grep -q "^geo-poc$"; then
        info "Cluster 'geo-poc' already exists, skipping"
    else
        kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
        info "Cluster created"
    fi
    kubectl cluster-info --context kind-geo-poc
}

# ── Step 2: namespaces ─────────────────────────────────────────────────────────

apply_namespaces() {
    log "Creating namespaces: fra, muc, ham"
    for dc in fra muc ham; do
        kubectl apply -f "$MANIFESTS/$dc/00-namespace.yaml"
    done
}

# ── Step 3: external Keepers ───────────────────────────────────────────────────

deploy_keepers() {
    log "Deploying external ClickHouse Keepers"
    for dc in fra muc ham; do
        info "Applying $dc keeper"
        kubectl apply -f "$MANIFESTS/$dc/01-keeper.yaml"
    done

    log "Waiting for Keepers to be Ready"
    for dc in fra muc ham; do
        wait_for_pods "$dc" "app=${dc}-keeper" 1
    done
}

# ── Step 4: ClickHouse via Helm ────────────────────────────────────────────────

deploy_clickhouse() {
    log "Adding ClickHouse Helm repo"
    helm repo add clickhouse https://charts.clickhouse.com 2>/dev/null || true
    helm repo update clickhouse

    log "Installing ClickHouse clusters via Helm"
    for dc in fra muc ham; do
        if helm status "$dc" -n "$dc" &>/dev/null; then
            info "Helm release '$dc' already exists in ns $dc, upgrading"
            helm upgrade "$dc" clickhouse/clickhouse \
                --namespace "$dc" \
                --values "$HELM_VALUES/$dc/values.yaml" \
                --wait --timeout 5m
        else
            info "Installing Helm release '$dc' in ns $dc"
            helm install "$dc" clickhouse/clickhouse \
                --namespace "$dc" \
                --values "$HELM_VALUES/$dc/values.yaml" \
                --wait --timeout 5m
        fi
    done

    log "Applying NodePort services for host access"
    for dc in fra muc ham; do
        kubectl apply -f "$MANIFESTS/$dc/02-nodeport.yaml"
    done
}

# ── Step 5: verify actual pod naming ──────────────────────────────────────────
# The Helm chart's StatefulSet naming may differ from what we assumed in
# remote_servers.xml (fra-shard-0-0.fra-headless.fra.svc.cluster.local).
# This step prints the actual FQDNs so you can patch values.yaml if needed.

verify_naming() {
    log "Actual CH pod/service names (verify against remote_servers.xml in values.yaml)"
    for dc in fra muc ham; do
        info "--- $dc ---"
        kubectl get pods -n "$dc" -l "app.kubernetes.io/name=clickhouse" \
            -o custom-columns="NAME:.metadata.name,STATUS:.status.phase" 2>/dev/null || true
        kubectl get svc -n "$dc" 2>/dev/null | grep -v "keeper" | grep -v "nodeport" || true
    done

    echo ""
    info "If the headless service or pod names differ from 'fra-shard-0-0.fra-headless.fra.svc.cluster.local',"
    info "update poc/helm/{dc}/values.yaml remote_servers.xml and re-run:"
    info "  helm upgrade fra clickhouse/clickhouse -n fra -f poc/helm/fra/values.yaml --wait"
    info "  kubectl exec -n fra \$(kubectl get pod -n fra -l app.kubernetes.io/name=clickhouse -o name | head -1) -- clickhouse-client --query 'SYSTEM RELOAD CONFIG'"
}

# ── Step 6: wait for CH to be Ready ───────────────────────────────────────────

wait_for_clickhouse() {
    log "Waiting for ClickHouse pods to be Ready"
    for dc in fra muc ham; do
        wait_for_pods "$dc" "app.kubernetes.io/name=clickhouse" 1
    done
}

# ── Step 7: apply schemas ──────────────────────────────────────────────────────

apply_schemas() {
    log "Applying ClickHouse schemas (Tier 1 → 2 → 3 → RBAC)"
    bash "$SCRIPT_DIR/scripts/apply-schemas.sh"
}

# ── Step 8: print access summary ──────────────────────────────────────────────

print_summary() {
    log "POC is ready"
    echo ""
    echo "  Host access (via NodePort, mapped from kind-config.yaml):"
    echo "    FRA HTTP: http://localhost:8801   native TCP: localhost:9801"
    echo "    MUC HTTP: http://localhost:8802   native TCP: localhost:9802"
    echo "    HAM HTTP: http://localhost:8803   native TCP: localhost:9803"
    echo ""
    echo "  Quick test (clickhouse-client):"
    echo "    clickhouse-client --host localhost --port 9801 \\"
    echo "      --query \"SELECT dc_name, count() FROM default.dist_test_global GROUP BY dc_name ORDER BY dc_name\""
    echo ""
    echo "  Or via HTTP:"
    echo "    curl 'http://localhost:8801/?query=SELECT+dc_name,count()+FROM+default.dist_test_global+GROUP+BY+dc_name'"
    echo ""
    echo "  Run verification suite:"
    echo "    bash poc/scripts/verify.sh"
    echo ""
    echo "  Tear down:"
    echo "    bash poc/teardown.sh"
}

# ── main ──────────────────────────────────────────────────────────────────────

check_prereqs
create_cluster
apply_namespaces
deploy_keepers
deploy_clickhouse
verify_naming
wait_for_clickhouse
apply_schemas
print_summary
