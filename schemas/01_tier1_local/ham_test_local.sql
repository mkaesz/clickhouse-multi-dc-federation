-- Tier 1: Local table (the actual data)
-- DC: HAM
-- Engine: ReplicatedMergeTree (no shared storage across DCs -- each DC coordinates
-- replication only via its own local Keeper ensemble, ham_local)

CREATE TABLE default.test_local ON CLUSTER 'ham_local'
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    dc_name    LowCardinality(String) DEFAULT 'HAM'
)
ENGINE = ReplicatedMergeTree('/clickhouse/{cluster}/tables/{shard}/test_local', '{replica}')
ORDER BY (id, event_time);
