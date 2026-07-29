#!/usr/bin/env bash
# Runs smoke tests: inserts, cross-DC query, shard pruning, RBAC check.
# Run from the repo root: bash scripts/verify.sh

set -euo pipefail

FRA_CTX="kind-clickhouse-multi-region-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-region-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-region-federation-demo-ham"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

run_query() {
    local ctx="$1" ns="$2" pod="$3" query="$4"
    info "[$ns] $query"
    kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
        clickhouse client --query "$query"
}

POD_FRA=$(ch_pod "$FRA_CTX" fra)
POD_MUC=$(ch_pod "$MUC_CTX" muc)
POD_HAM=$(ch_pod "$HAM_CTX" ham)

log "Reset local tables for repeatable results"
run_query "$FRA_CTX" fra "$POD_FRA" "TRUNCATE TABLE default.otel_local"
run_query "$MUC_CTX" muc "$POD_MUC" "TRUNCATE TABLE default.otel_local"
run_query "$HAM_CTX" ham "$POD_HAM" "TRUNCATE TABLE default.otel_local"

log "Insert sample rows into each DC (writes go to the local MergeTree only)"
run_query "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (1, now(), 'test from FRA')"
run_query "$MUC_CTX" muc "$POD_MUC" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (2, now(), 'test from MUC')"
run_query "$HAM_CTX" ham "$POD_HAM" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (3, now(), 'test from HAM')"

log "Verify each DC's local table has its own region only"
for pair in "fra:$FRA_CTX" "muc:$MUC_CTX" "ham:$HAM_CTX"; do
    dc="${pair%%:*}"; ctx="${pair##*:}"
    pod=$(ch_pod "$ctx" "$dc")
    run_query "$ctx" "$dc" "$pod" \
        "SELECT region, count() FROM default.otel_local GROUP BY region"
done

log "Cross-DC aggregation via otel_global (from FRA)"
run_query "$FRA_CTX" fra "$POD_FRA" \
    "SELECT region, count() AS row_count FROM default.otel_global GROUP BY region ORDER BY region"

log "Shard pruning: single-DC filter (should touch 1 shard)"
run_query "$FRA_CTX" fra "$POD_FRA" \
    "EXPLAIN SELECT * FROM default.otel_global WHERE region = 'MUC' SETTINGS optimize_skip_unused_shards = 1"

log "Shard pruning: IN() filter (should touch 2 shards)"
run_query "$FRA_CTX" fra "$POD_FRA" \
    "EXPLAIN SELECT * FROM default.otel_global WHERE region IN ('MUC','HAM') SETTINGS optimize_skip_unused_shards = 1"

log "RBAC: confirm app_writer cannot INSERT into otel_global"
kubectl exec --context "$FRA_CTX" -n fra "$POD_FRA" -- \
    clickhouse client --query "
        CREATE USER IF NOT EXISTS rbac_test_user IDENTIFIED WITH no_password;
        GRANT app_writer TO rbac_test_user;
    " 2>&1

result=$(kubectl exec --context "$FRA_CTX" -n fra "$POD_FRA" -- \
    clickhouse client --user rbac_test_user \
    --query "INSERT INTO default.otel_global (id, event_time, payload, region) VALUES (9999, now(), 'should fail', 'FRA')" \
    2>&1 || true)

if echo "$result" | grep -qE "Code: 497|Not enough privileges"; then
    info "PASS: insert correctly rejected (Code 497 - Not enough privileges)"
else
    info "FAIL: expected Code 497 but got: $result"
fi

log "Verification complete"
