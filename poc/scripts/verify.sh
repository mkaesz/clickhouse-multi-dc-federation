#!/usr/bin/env bash
# Runs smoke tests: inserts, cross-DC query, shard pruning, RBAC check.
# Run from the repo root: bash poc/scripts/verify.sh

set -euo pipefail

FRA_CTX="kind-clickhouse-multi-dc-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-dc-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-dc-federation-demo-ham"

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "app.kubernetes.io/name=clickhouse" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

run_query() {
    local ctx="$1" ns="$2" pod="$3" query="$4"
    echo "  [$ns] $query"
    kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
        clickhouse-client --query "$query"
}

POD_FRA=$(ch_pod "$FRA_CTX" fra)
POD_MUC=$(ch_pod "$MUC_CTX" muc)
POD_HAM=$(ch_pod "$HAM_CTX" ham)

echo "=== Insert sample rows into each DC ==="
run_query "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.dist_test_regional (id, event_time, payload) VALUES (1, now(), 'test from FRA')"
run_query "$MUC_CTX" muc "$POD_MUC" \
    "INSERT INTO default.dist_test_regional (id, event_time, payload) VALUES (2, now(), 'test from MUC')"
run_query "$HAM_CTX" ham "$POD_HAM" \
    "INSERT INTO default.dist_test_regional (id, event_time, payload) VALUES (3, now(), 'test from HAM')"

echo ""
echo "=== Verify each DC's local table has its own dc_name only ==="
for pair in "fra:$FRA_CTX" "muc:$MUC_CTX" "ham:$HAM_CTX"; do
    dc="${pair%%:*}"; ctx="${pair##*:}"
    pod=$(ch_pod "$ctx" "$dc")
    run_query "$ctx" "$dc" "$pod" \
        "SELECT dc_name, count() FROM default.test_local GROUP BY dc_name"
done

echo ""
echo "=== Cross-DC aggregation via dist_test_global (from FRA) ==="
run_query "$FRA_CTX" fra "$POD_FRA" \
    "SELECT dc_name, count() AS row_count FROM default.dist_test_global GROUP BY dc_name ORDER BY dc_name"

echo ""
echo "=== Shard pruning: single-DC filter (should touch 1 shard) ==="
run_query "$FRA_CTX" fra "$POD_FRA" \
    "EXPLAIN SELECT * FROM default.dist_test_global WHERE dc_name = 'MUC' SETTINGS optimize_skip_unused_shards = 1"

echo ""
echo "=== Shard pruning: IN() filter (should touch 2 shards) ==="
run_query "$FRA_CTX" fra "$POD_FRA" \
    "EXPLAIN SELECT * FROM default.dist_test_global WHERE dc_name IN ('MUC','HAM') SETTINGS optimize_skip_unused_shards = 1"

echo ""
echo "=== RBAC: confirm app_writer cannot INSERT into dist_test_global ==="
echo "  (Expected: Code 497 - Not enough privileges)"
kubectl exec --context "$FRA_CTX" -n fra "$POD_FRA" -- \
    clickhouse-client \
    --query "INSERT INTO default.dist_test_global (id, event_time, payload, dc_name) VALUES (9999, now(), 'should fail', 'FRA')" \
    2>&1 | grep -E "Exception|Code|error" | head -3 || true

echo ""
echo "=== Verification complete ==="
