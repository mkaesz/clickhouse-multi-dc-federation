-- Tier 1: Local table (the actual data)
-- DC: FRA
-- The operator creates 'default' as a Replicated database, so ReplicatedMergeTree
-- must be used without explicit Keeper paths (the database handles them).

CREATE TABLE IF NOT EXISTS default.otel_local ON CLUSTER 'default'
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    Region     LowCardinality(String) DEFAULT 'FRA'
)
ENGINE = ReplicatedMergeTree()
ORDER BY (id, event_time);
