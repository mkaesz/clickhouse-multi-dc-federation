#!/usr/bin/env bash
# Discovers each DC's kind node IP and injects federated_dcs remote_servers
# into every ClickHouseCluster CR via kubectl patch, then reloads CH config.
#
# Cross-cluster routing: all kind clusters share the Docker/Podman "kind"
# network. A pod in FRA can reach NodePort 30901 on the MUC node IP directly.
#
# Run from the repo root: bash poc/scripts/patch-federation.sh

set -euo pipefail

FRA_CTX="kind-clickhouse-multi-dc-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-dc-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-dc-federation-demo-ham"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

# ── Get node IPs ───────────────────────────────────────────────────────────────

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

# ── Patch ClickHouseCluster CRs ────────────────────────────────────────────────
# The operator writes spec.settings.extraConfig as-is to
# /etc/clickhouse-server/config.d/99-extra-config.yaml.
# ClickHouse merges this YAML with the operator-generated 00-cluster.yaml
# (which already defines remote_servers.default for the local cluster).
# Adding federated_dcs here creates a second remote_servers entry.

patch_cr() {
    local dc="$1"
    local ctx="$2"

    info "Patching ClickHouseCluster/$dc in $ctx"

    # Build JSON patch (raw JSON written verbatim to 99-extra-config.yaml)
    local patch
    patch=$(cat <<JSON
{
  "spec": {
    "settings": {
      "extraConfig": {
        "remote_servers": {
          "federated_dcs": {
            "shard": [
              {"replica": {"host": "${FRA_IP}", "port": 30901}},
              {"replica": {"host": "${MUC_IP}", "port": 30902}},
              {"replica": {"host": "${HAM_IP}", "port": 30903}}
            ]
          }
        }
      }
    }
  }
}
JSON
)

    kubectl patch clickhousecluster "$dc" \
        --context "$ctx" \
        --namespace "$dc" \
        --type merge \
        --patch "$patch"
}

log "Patching FRA"
patch_cr fra "$FRA_CTX"

log "Patching MUC"
patch_cr muc "$MUC_CTX"

log "Patching HAM"
patch_cr ham "$HAM_CTX"

# ── Wait for operator to roll out updated config ───────────────────────────────
# The extraConfig change triggers RequiresRestart=true, so the operator
# will restart CH pods with the new config. Wait for them to come back.

wait_for_ch_pod() {
    local dc="$1" ctx="$2"
    local max=60 i=0
    info "Waiting for $dc CH pod to be Ready after config patch ..."
    until [ "$(kubectl get pods --context "$ctx" -n "$dc" \
        -l 'clickhouse.com/role=clickhouse-server' \
        -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' 2>/dev/null \
        | grep -c '^true$' || true)" -ge 1 ]; do
        i=$((i+1))
        [ "$i" -ge "$max" ] && echo "  ERROR: Timed out" && exit 1
        sleep 5
    done
    info "  $dc CH pod Ready"
}

log "Waiting for CH pods to re-stabilize after config patch"
wait_for_ch_pod fra "$FRA_CTX"
wait_for_ch_pod muc "$MUC_CTX"
wait_for_ch_pod ham "$HAM_CTX"

# ── Trigger explicit config reload (belt-and-suspenders) ─────────────────────

reload_config() {
    local dc="$1" ctx="$2"
    local pod
    pod=$(kubectl get pods --context "$ctx" -n "$dc" \
        -l 'clickhouse.com/role=clickhouse-server' \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
        info "SYSTEM RELOAD CONFIG on $dc/$pod"
        kubectl exec --context "$ctx" -n "$dc" "$pod" -- \
            clickhouse-client --query "SYSTEM RELOAD CONFIG" 2>/dev/null || true
    fi
}

log "Reloading ClickHouse config"
reload_config fra "$FRA_CTX"
reload_config muc "$MUC_CTX"
reload_config ham "$HAM_CTX"

echo ""
echo "=== Federation patch complete ==="
echo "   FRA → $FRA_IP:30901"
echo "   MUC → $MUC_IP:30902"
echo "   HAM → $HAM_IP:30903"
