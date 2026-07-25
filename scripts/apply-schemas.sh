#!/usr/bin/env bash
# Applies ClickHouse schemas in the correct deployment order across all 3 DCs.
# Run from the repo root: bash scripts/apply-schemas.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMAS="$REPO_ROOT/schemas"

FRA_CTX="kind-clickhouse-multi-dc-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-dc-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-dc-federation-demo-ham"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

wait_for_ch() {
    local ctx="$1" ns="$2" pod="$3"
    local max=60 i=0
    info "Waiting for clickhouse client in $ns/$pod ..."
    until kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
            clickhouse client --query "SELECT 1" &>/dev/null; do
        i=$((i + 1))
        [ "$i" -ge "$max" ] && echo "ERROR: CH not responding in $ns/$pod" && exit 1
        sleep 3
    done
    info "OK"
}

run_sql() {
    local ctx="$1" ns="$2" pod="$3" file="$4"
    info "--> [$ns] $(basename "$file")"
    kubectl exec -i --context "$ctx" -n "$ns" "$pod" -- \
        clickhouse client --multiquery --echo < "$file"
}

log "Discovering CH pods"
POD_FRA=$(ch_pod "$FRA_CTX" fra)
POD_MUC=$(ch_pod "$MUC_CTX" muc)
POD_HAM=$(ch_pod "$HAM_CTX" ham)
info "FRA: $POD_FRA  MUC: $POD_MUC  HAM: $POD_HAM"

log "Waiting for CH to accept connections"
wait_for_ch "$FRA_CTX" fra "$POD_FRA"
wait_for_ch "$MUC_CTX" muc "$POD_MUC"
wait_for_ch "$HAM_CTX" ham "$POD_HAM"

log "Step 1: Tier 1 — local tables (ReplicatedMergeTree)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/01_tier1_local/fra_test_local.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/01_tier1_local/muc_test_local.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/01_tier1_local/ham_test_local.sql"

log "Step 2: Tier 2 — regional Distributed tables"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/02_tier2_regional/fra_dist_test_regional.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/02_tier2_regional/muc_dist_test_regional.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/02_tier2_regional/ham_dist_test_regional.sql"

log "Step 3: Tier 3 — global Distributed tables (cross-DC)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/03_tier3_global/fra_dist_test_global.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/03_tier3_global/muc_dist_test_global.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/03_tier3_global/ham_dist_test_global.sql"

log "Step 4: RBAC — roles and grants (per-DC)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/04_rbac/roles_and_grants.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/04_rbac/roles_and_grants.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/04_rbac/roles_and_grants.sql"

log "Schemas applied successfully"
