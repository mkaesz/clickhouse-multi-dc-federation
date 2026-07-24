#!/usr/bin/env bash
# Full POC setup: one kind cluster per DC (FRA / MUC / HAM).
# Each cluster gets the official ClickHouse operator, a KeeperCluster, and a
# ClickHouseCluster.  Cross-DC federation is wired via NodePort on the shared
# kind Docker/Podman network.
#
# Run from the repo root:  bash poc/setup.sh
#
# Prerequisites: kind, kubectl, helm, docker OR podman

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/manifests"

FRA_CTX="kind-clickhouse-multi-dc-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-dc-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-dc-federation-demo-ham"

OPERATOR_NS="clickhouse-operator-system"
OPERATOR_VERSION="0.0.7"
OPERATOR_CHART_URL="https://github.com/ClickHouse/clickhouse-operator/releases/download/v${OPERATOR_VERSION}/clickhouse-operator-helm-${OPERATOR_VERSION}.tgz"
OPERATOR_CHART_TGZ="/tmp/clickhouse-operator-helm-${OPERATOR_VERSION}.tgz"

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
            kind create cluster --config "$SCRIPT_DIR/manifests/${dc}/kind.yaml"
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

# ── Step 3: Install ClickHouse operator ───────────────────────────────────────
# Installed with webhooks disabled — no cert-manager dependency for POC.

install_operator() {
    log "Installing ClickHouse operator (webhooks disabled)"

    if [ ! -f "$OPERATOR_CHART_TGZ" ]; then
        info "Downloading operator chart v${OPERATOR_VERSION} ..."
        curl -fsSL "$OPERATOR_CHART_URL" -o "$OPERATOR_CHART_TGZ"
    fi

    for dc in fra muc ham; do
        local ctx="kind-clickhouse-multi-dc-federation-demo-${dc}"
        if helm status clickhouse-operator --kube-context "$ctx" -n "$OPERATOR_NS" &>/dev/null; then
            info "Operator already installed in $dc, skipping"
        else
            info "Installing operator in $dc"
            helm install clickhouse-operator "$OPERATOR_CHART_TGZ" \
                --kube-context "$ctx" \
                --create-namespace \
                --namespace "$OPERATOR_NS" \
                --set webhook.enabled=false \
                --set certManager.enabled=false \
                --wait --timeout 3m
        fi
    done
}

# ── Step 4: Deploy KeeperCluster + ClickHouseCluster CRs ─────────────────────
# The operator auto-wires Keeper → ClickHouse; no manual config injection needed.
# Pod naming (ClickHouseCluster named 'fra', shard 0, replica 0):
#   StatefulSet: fra-clickhouse-0-0   Pod: fra-clickhouse-0-0-0
#   Headless svc: fra-clickhouse-headless
# Pod naming (KeeperCluster named 'fra', replica 0):
#   StatefulSet: fra-keeper-0         Pod: fra-keeper-0-0
#   Headless svc: fra-keeper-headless

deploy_clickhouse_clusters() {
    log "Deploying KeeperCluster + ClickHouseCluster CRs"
    kubectl apply --context "$FRA_CTX" -f "$MANIFESTS/fra/01-clickhouse-crs.yaml"
    kubectl apply --context "$MUC_CTX" -f "$MANIFESTS/muc/01-clickhouse-crs.yaml"
    kubectl apply --context "$HAM_CTX" -f "$MANIFESTS/ham/01-clickhouse-crs.yaml"

    log "Applying NodePort services"
    kubectl apply --context "$FRA_CTX" -f "$MANIFESTS/fra/02-nodeport.yaml"
    kubectl apply --context "$MUC_CTX" -f "$MANIFESTS/muc/02-nodeport.yaml"
    kubectl apply --context "$HAM_CTX" -f "$MANIFESTS/ham/02-nodeport.yaml"
}

# ── Step 5: Wait for Keeper pods Ready ────────────────────────────────────────

wait_for_keeper() {
    log "Waiting for Keeper pods to be Ready"
    wait_for_pods "$FRA_CTX" fra "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$MUC_CTX" muc "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$HAM_CTX" ham "clickhouse.com/role=clickhouse-keeper" 1
}

# ── Step 6: Wait for ClickHouse pods Ready ────────────────────────────────────

wait_for_clickhouse() {
    log "Waiting for ClickHouse pods to be Ready"
    wait_for_pods "$FRA_CTX" fra "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$MUC_CTX" muc "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$HAM_CTX" ham "clickhouse.com/role=clickhouse-server" 1
}

# ── Step 7: Patch federated_dcs remote_servers ────────────────────────────────

patch_federation() {
    log "Patching federated_dcs remote_servers with real node IPs"
    bash "$SCRIPT_DIR/scripts/patch-federation.sh"
}

# ── Step 8: Set up TLS (certs, secrets, NodePorts, CR patches) ────────────────

setup_tls() {
    log "Setting up TLS for cross-DC communication"
    bash "$SCRIPT_DIR/scripts/setup-tls.sh"
}

# ── Step 9: Apply schemas ──────────────────────────────────────────────────────

apply_schemas() {
    log "Applying ClickHouse schemas (Tier 1 → 2 → 3 → RBAC)"
    bash "$SCRIPT_DIR/scripts/apply-schemas.sh"
}

# ── Step 10: Print access summary ─────────────────────────────────────────────

print_summary() {
    log "POC is ready"
    echo ""
    echo "  Host access (NodePort → kind control-plane → CH pod):"
    echo "    FRA  HTTP: http://localhost:8801    TCP: clickhouse-client --host localhost --port 9801"
    echo "    MUC  HTTP: http://localhost:8802    TCP: clickhouse-client --host localhost --port 9802"
    echo "    HAM  HTTP: http://localhost:8803    TCP: clickhouse-client --host localhost --port 9803"
    echo ""
    echo "  Host access (TLS):"
    echo "    FRA  clickhouse-client --host localhost --port 9841 --secure"
    echo "    MUC  clickhouse-client --host localhost --port 9842 --secure"
    echo "    HAM  clickhouse-client --host localhost --port 9843 --secure"
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
install_operator
deploy_clickhouse_clusters
wait_for_keeper
wait_for_clickhouse
patch_federation
setup_tls
apply_schemas
print_summary
