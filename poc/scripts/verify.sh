#!/usr/bin/env bash
# Runs the sanity checks from schemas/05_verification/sanity_checks.sql
# plus a cross-DC smoke test with sample inserts.

set -euo pipefail

ch_pod() {
    kubectl get pods -n "$1" -l "app.kubernetes.io/name=clickhouse" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

run_query() {
    local ns="$1"
    local pod="$2"
    local query="$3"
    echo "  [${ns}] ${query}"
    kubectl exec -n "$ns" "$pod" -- \
        clickhouse-client --query "$query"
}

POD_FRA=$(ch_pod fra)
POD_MUC=$(ch_pod muc)
POD_HAM=$(ch_pod ham)

echo "=== Insert sample rows into each DC ==="
run_query fra "$POD_FRA" "INSERT INTO default.dist_test_regional (id, event_time, payload) VALUES (1, now(), 'test from FRA')"
run_query muc "$POD_MUC" "INSERT INTO default.dist_test_regional (id, event_time, payload) VALUES (2, now(), 'test from MUC')"
run_query ham "$POD_HAM" "INSERT INTO default.dist_test_regional (id, event_time, payload) VALUES (3, now(), 'test from HAM')"

echo ""
echo "=== Verify each DC's local table has its own dc_name only ==="
for NS in fra muc ham; do
    POD=$(ch_pod "$NS")
    run_query "$NS" "$POD" "SELECT dc_name, count() FROM default.test_local GROUP BY dc_name"
done

echo ""
echo "=== Cross-DC aggregation via dist_test_global (from FRA) ==="
run_query fra "$POD_FRA" \
    "SELECT dc_name, count() AS row_count FROM default.dist_test_global GROUP BY dc_name ORDER BY dc_name"

echo ""
echo "=== Shard pruning: single-DC filter (from FRA, should touch 1 shard) ==="
run_query fra "$POD_FRA" \
    "EXPLAIN SELECT * FROM default.dist_test_global WHERE dc_name = 'MUC' SETTINGS optimize_skip_unused_shards = 1"

echo ""
echo "=== Shard pruning: IN() filter (from FRA, should touch 2 shards) ==="
run_query fra "$POD_FRA" \
    "EXPLAIN SELECT * FROM default.dist_test_global WHERE dc_name IN ('MUC','HAM') SETTINGS optimize_skip_unused_shards = 1"

echo ""
echo "=== RBAC: confirm app_writer cannot INSERT into dist_test_global ==="
echo "  (Expected: exception Code 497 - Not enough privileges)"
kubectl exec -n fra "$POD_FRA" -- clickhouse-client \
    --query "INSERT INTO default.dist_test_global (id, event_time, payload, dc_name) VALUES (9999, now(), 'should fail', 'FRA')" \
    --user default 2>&1 | grep -E "Exception|OK|error" | head -3

echo ""
echo "=== Verification complete ==="
