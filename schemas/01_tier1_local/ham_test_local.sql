-- Tier 1: Local table (the actual data)
-- DC: HAM
-- The operator creates 'default' as a Replicated database, so ReplicatedMergeTree
-- must be used without explicit ZooKeeper paths (the database handles them).

CREATE TABLE IF NOT EXISTS default.test_local ON CLUSTER 'default'
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    dc_name    LowCardinality(String) DEFAULT 'HAM'
)
ENGINE = ReplicatedMergeTree()
ORDER BY (id, event_time);
