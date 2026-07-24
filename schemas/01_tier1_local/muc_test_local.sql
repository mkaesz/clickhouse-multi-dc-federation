-- Tier 1: Local table (the actual data)
-- DC: MUC
-- Engine: ReplicatedMergeTree (no shared storage across DCs -- each DC coordinates
-- replication only via its own local Keeper ensemble, muc_local)

CREATE TABLE default.test_local ON CLUSTER 'muc_local'
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    dc_name    LowCardinality(String) DEFAULT 'MUC'
)
ENGINE = ReplicatedMergeTree('/clickhouse/{cluster}/tables/{shard}/test_local', '{replica}')
ORDER BY (id, event_time);
