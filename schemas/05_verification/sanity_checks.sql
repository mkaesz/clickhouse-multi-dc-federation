-- Sanity checks -- run after all Tier 1/2/3 schemas are deployed to all 3 DCs.

-- 1. Confirm each DC's local table only holds rows tagged with its own dc_name.
--    Run this individually against each DC's local endpoint.
SELECT dc_name, count() FROM default.test_local GROUP BY dc_name;

-- 2. Confirm shard pruning works on the global table for a single-DC read.
EXPLAIN SELECT * FROM default.dist_test_global
WHERE dc_name = 'MUC'
SETTINGS optimize_skip_unused_shards = 1;
-- Expect: only 1 shard referenced in the plan.

-- 3. Confirm shard pruning works for a multi-DC IN(...) read.
EXPLAIN SELECT * FROM default.dist_test_global
WHERE dc_name IN ('MUC', 'HAM')
SETTINGS optimize_skip_unused_shards = 1;
-- Expect: only 2 shards referenced in the plan (FRA skipped).

-- 4. Example cross-DC aggregation query.
SELECT
    dc_name,
    count() AS errors
FROM default.dist_test_global
WHERE dc_name IN ('MUC', 'HAM')
  AND event_time >= now() - toIntervalHour(1)
GROUP BY ALL
ORDER BY ALL ASC
SETTINGS optimize_skip_unused_shards = 1;

-- 5. Confirm app_writer cannot write to the global table (should fail with
--    an access-denied error when run as a user carrying only app_writer).
-- INSERT INTO default.dist_test_global VALUES (1, now(), 'test', 'FRA');
