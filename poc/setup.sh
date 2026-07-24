#!/usr/bin/env bash
# Full POC setup: one kind cluster per DC (FRA / MUC / HAM).
# Each cluster gets its own external Keeper + ClickHouse (via Helm).
# Cross-DC federation is wired via NodePort on the shared kind network.
#
# Run from the repo root:  bash poc/setup.sh
#
# Prerequisites: kind, kubectl, helm, docker OR podman

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/manifests"
HELM_VALUES="$SCRIPT_DIR/helm"

FRA_CTX="kind-clickhouse-multi-dc-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-dc-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-dc-federation-demo-ham"

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

detect_runtime() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        CONTAINER_RUNTIME=docker
    elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        CONTAINER_RUNTIME=podman
        export KIND_EXPERIMENTAL_PROVIDER=podman
    else
        echo "ERROR: no container runtime found or running."
        echo "  Start Docker Desktop / podman machine start, then retry."
        exit 1
    fi
    info "Container runtime: $CONTAINER_RUNTIME"
}

check_prereqs() {
    log "Checking prerequisites"
    local missing=()
    for cmd in kind kubectl helm; do
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
    detect_runtime
}

wait_for_pods() {
    bash "$SCRIPT_DIR/scripts/wait-for-pods.sh" "$@"
}

# ── Step 1: Create 3 kind clusters ────────────────────────────────────────────

create_clusters() {
    log "Creating kind clusters (one per DC)"
    for dc in fra muc ham; do
        local cluster_name="clickhouse-multi-dc-federation-demo-${dc}"
        if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
            info "Cluster '$cluster_name' already exists, skipping"
        else
            info "Creating cluster '$cluster_name'"
            kind create cluster --config "$SCRIPT_DIR/kind-${dc}.yaml"
        fi
    done

    info "Cluster contexts:"
    for dc in fra muc ham; do
        kubectl cluster-info --context "kind-clickhouse-multi-dc-federation-demo-${dc}" 2>/dev/null \
            | head -1 | sed 's/^/    /'
    done
}

# ── Step 2: Namespaces ─────────────────────────────────────────────────────────

apply_namespaces() {
    log "Creating namespaces"
    kubectl apply --context "$FRA_CTX" -f "$MANIFESTS/fra/00-namespace.yaml"
    kubectl apply --context "$MUC_CTX" -f "$MANIFESTS/muc/00-namespace.yaml"
    kubectl apply --context "$HAM_CTX" -f "$MANIFESTS/ham/00-namespace.yaml"
}

# ── Step 3: External Keepers ───────────────────────────────────────────────────

deploy_keepers() {
    log "Deploying external ClickHouse Keepers"
    kubectl apply --context "$FRA_CTX" -f "$MANIFESTS/fra/01-keeper.yaml"
    kubectl apply --context "$MUC_CTX" -f "$MANIFESTS/muc/01-keeper.yaml"
    kubectl apply --context "$HAM_CTX" -f "$MANIFESTS/ham/01-keeper.yaml"

    log "Waiting for Keepers to be Ready"
    wait_for_pods "$FRA_CTX" fra "app=fra-keeper" 1
    wait_for_pods "$MUC_CTX" muc "app=muc-keeper" 1
    wait_for_pods "$HAM_CTX" ham "app=ham-keeper" 1
}

# ── Step 4: ClickHouse via Helm ────────────────────────────────────────────────

deploy_clickhouse() {
    log "Adding ClickHouse Helm repo"
    helm repo add clickhouse https://charts.clickhouse.com 2>/dev/null || true
    helm repo update clickhouse

    log "Installing ClickHouse on each cluster"
    for dc in fra muc ham; do
        local ctx="kind-clickhouse-multi-dc-federation-demo-${dc}"
        if helm status "$dc" --kube-context "$ctx" -n "$dc" &>/dev/null; then
            info "Release '$dc' already exists in ns=$dc ctx=$ctx, upgrading"
            helm upgrade "$dc" clickhouse/clickhouse \
                --kube-context "$ctx" \
                --namespace "$dc" \
                --values "$HELM_VALUES/$dc/values.yaml" \
                --wait --timeout 5m
        else
            info "Installing release '$dc' in ns=$dc ctx=$ctx"
            helm install "$dc" clickhouse/clickhouse \
                --kube-context "$ctx" \
                --namespace "$dc" \
                --values "$HELM_VALUES/$dc/values.yaml" \
                --wait --timeout 5m
        fi
    done

    log "Applying NodePort services for host access"
    kubectl apply --context "$FRA_CTX" -f "$MANIFESTS/fra/02-nodeport.yaml"
    kubectl apply --context "$MUC_CTX" -f "$MANIFESTS/muc/02-nodeport.yaml"
    kubectl apply --context "$HAM_CTX" -f "$MANIFESTS/ham/02-nodeport.yaml"
}

# ── Step 5: Verify pod naming ──────────────────────────────────────────────────

verify_naming() {
    log "Actual CH pod/service names per cluster"
    for dc in fra muc ham; do
        local ctx="kind-clickhouse-multi-dc-federation-demo-${dc}"
        info "--- $dc ($ctx) ---"
        kubectl get pods --context "$ctx" -n "$dc" \
            -l "app.kubernetes.io/name=clickhouse" \
            -o custom-columns="NAME:.metadata.name,STATUS:.status.phase" 2>/dev/null || true
        kubectl get svc --context "$ctx" -n "$dc" 2>/dev/null \
            | grep -v "keeper" | grep -v "nodeport" || true
    done
    echo ""
    info "Expected headless service: {dc}-headless  |  pod: {dc}-shard-0-0"
    info "If names differ, update extraConfigFiles.remote_servers.xml in poc/helm/{dc}/values.yaml"
    info "then re-run: helm upgrade {dc} clickhouse/clickhouse --kube-context kind-clickhouse-multi-dc-federation-demo-{dc} --reuse-values --wait -f poc/helm/{dc}/values.yaml"
}

# ── Step 6: Wait for CH Ready ──────────────────────────────────────────────────

wait_for_clickhouse() {
    log "Waiting for ClickHouse pods to be Ready"
    wait_for_pods "$FRA_CTX" fra "app.kubernetes.io/name=clickhouse" 1
    wait_for_pods "$MUC_CTX" muc "app.kubernetes.io/name=clickhouse" 1
    wait_for_pods "$HAM_CTX" ham "app.kubernetes.io/name=clickhouse" 1
}

# ── Step 7: Patch federated_dcs remote_servers ────────────────────────────────

patch_federation() {
    log "Patching federated_dcs remote_servers with real node IPs"
    bash "$SCRIPT_DIR/scripts/patch-federation.sh"
}

# ── Step 8: Apply schemas ──────────────────────────────────────────────────────

apply_schemas() {
    log "Applying ClickHouse schemas (Tier 1 → 2 → 3 → RBAC)"
    bash "$SCRIPT_DIR/scripts/apply-schemas.sh"
}

# ── Step 9: Print access summary ──────────────────────────────────────────────

print_summary() {
    log "POC is ready"
    echo ""
    echo "  Host access (NodePort → kind control-plane → CH pod):"
    echo "    FRA  HTTP: http://localhost:8801    TCP: clickhouse-client --host localhost --port 9801"
    echo "    MUC  HTTP: http://localhost:8802    TCP: clickhouse-client --host localhost --port 9802"
    echo "    HAM  HTTP: http://localhost:8803    TCP: clickhouse-client --host localhost --port 9803"
    echo ""
    echo "  Cross-DC query (run from FRA):"
    echo "    clickhouse-client --host localhost --port 9801 \\"
    echo "      --query \"SELECT dc_name, count() FROM default.dist_test_global GROUP BY dc_name ORDER BY dc_name\""
    echo ""
    echo "  HTTP smoke test:"
    echo "    curl 'http://localhost:8801/?query=SELECT+dc_name,count()+FROM+default.dist_test_global+GROUP+BY+dc_name'"
    echo ""
    echo "  Full verification suite:"
    echo "    bash poc/scripts/verify.sh"
    echo ""
    echo "  Tear down all 3 clusters:"
    echo "    bash poc/teardown.sh"
}

# ── main ──────────────────────────────────────────────────────────────────────

check_prereqs
create_clusters
apply_namespaces
deploy_keepers
deploy_clickhouse
verify_naming
wait_for_clickhouse
patch_federation
apply_schemas
print_summary
