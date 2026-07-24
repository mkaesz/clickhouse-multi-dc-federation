#!/usr/bin/env bash
# Discovers each DC's kind node IP and injects federated_dcs remote_servers
# into every cluster via helm upgrade --reuse-values, then reloads CH config.
#
# Cross-cluster routing: all kind clusters share the Docker/Podman "kind"
# network, so a pod in cluster FRA can reach NodePort 30901 on the MUC
# node IP via kube-proxy NAT. No additional network setup required.
#
# Run from the repo root: bash poc/scripts/patch-federation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_VALUES="$SCRIPT_DIR/../helm"

FRA_CTX="kind-clickhouse-multi-dc-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-dc-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-dc-federation-demo-ham"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

# ── Get node IPs ───────────────────────────────────────────────────────────────
# In kind, all cluster nodes are on the shared "kind" Docker/Podman network.
# Their InternalIP is directly reachable from pods in other kind clusters
# (traffic is masqueraded through the local node).

log "Discovering kind node IPs"
FRA_IP=$(kubectl get nodes --context "$FRA_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
MUC_IP=$(kubectl get nodes --context "$MUC_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
HAM_IP=$(kubectl get nodes --context "$HAM_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

info "FRA node IP: $FRA_IP  (NodePort 30901)"
info "MUC node IP: $MUC_IP  (NodePort 30902)"
info "HAM node IP: $HAM_IP  (NodePort 30903)"

if [ -z "$FRA_IP" ] || [ -z "$MUC_IP" ] || [ -z "$HAM_IP" ]; then
    echo "ERROR: could not determine one or more node IPs"
    exit 1
fi

# ── Generate values patch ──────────────────────────────────────────────────────

write_federation_patch() {
    local out="$1"
    local local_cluster="$2"
    local local_host="$3"
    local local_port="${4:-9000}"

    # Build the XML in a variable first, then emit valid YAML literal block
    local xml
    xml=$(cat <<XML
<clickhouse>
  <remote_servers replace="1">
    <${local_cluster}>
      <shard>
        <replica>
          <host>${local_host}</host>
          <port>${local_port}</port>
        </replica>
      </shard>
    </${local_cluster}>
    <federated_dcs>
      <shard>
        <replica>
          <host>${FRA_IP}</host>
          <port>30901</port>
        </replica>
      </shard>
      <shard>
        <replica>
          <host>${MUC_IP}</host>
          <port>30902</port>
        </replica>
      </shard>
      <shard>
        <replica>
          <host>${HAM_IP}</host>
          <port>30903</port>
        </replica>
      </shard>
    </federated_dcs>
  </remote_servers>
</clickhouse>
XML
)

    printf 'extraConfigFiles:\n' > "$out"
    printf '  remote_servers.xml: |\n' >> "$out"
    while IFS= read -r line; do
        printf '    %s\n' "$line" >> "$out"
    done <<< "$xml"
}

# ── Apply patch to each cluster ────────────────────────────────────────────────

apply_patch() {
    local dc="$1"
    local ctx="$2"
    local local_cluster="${dc}_local"
    local local_host="${dc}-shard-0-0.${dc}-headless.${dc}.svc.cluster.local"
    local patch_file
    patch_file=$(mktemp /tmp/federation-patch-${dc}-XXXXXX.yaml)

    info "Writing federation patch for $dc → $patch_file"
    write_federation_patch "$patch_file" "$local_cluster" "$local_host"

    info "helm upgrade $dc (--reuse-values + federation patch)"
    helm upgrade "$dc" clickhouse/clickhouse \
        --kube-context "$ctx" \
        --namespace "$dc" \
        --reuse-values \
        --values "$patch_file" \
        --wait --timeout 3m

    rm -f "$patch_file"
}

log "Patching FRA"
apply_patch fra "$FRA_CTX"

log "Patching MUC"
apply_patch muc "$MUC_CTX"

log "Patching HAM"
apply_patch ham "$HAM_CTX"

# ── Reload config (belt-and-suspenders after Helm upgrade) ────────────────────

reload_config() {
    local dc="$1"
    local ctx="$2"
    local pod
    pod=$(kubectl get pods --context "$ctx" -n "$dc" \
        -l "app.kubernetes.io/name=clickhouse" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
        info "SYSTEM RELOAD CONFIG on $dc/$pod"
        kubectl exec --context "$ctx" -n "$dc" "$pod" -- \
            clickhouse-client --query "SYSTEM RELOAD CONFIG" 2>/dev/null || true
    fi
}

log "Reloading ClickHouse config on all DCs"
reload_config fra "$FRA_CTX"
reload_config muc "$MUC_CTX"
reload_config ham "$HAM_CTX"

echo ""
echo "=== Federation patch complete ==="
echo "   FRA → $FRA_IP:30901"
echo "   MUC → $MUC_IP:30902"
echo "   HAM → $HAM_IP:30903"
