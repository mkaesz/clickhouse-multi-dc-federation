-- Tier 3: Global distributed table (fan-out across all 3 DCs)
-- Requires otel_regional to already exist in FRA, MUC, and HAM, requires the
-- global remote_servers definition (3 shards: FRA/MUC/HAM) to be present,
-- and requires the default.regionToShard dictionary (see dict_regionToShard.sql).

CREATE TABLE IF NOT EXISTS default.otel_global ON CLUSTER 'default'
AS default.otel_local
ENGINE = Distributed(
    'global',
    default,
    otel_regional,
    -- Sharding key derived from cluster topology via the regionToShard
    -- dictionary (dc_name -> 0-based shard number), replacing the hardcoded
    -- transform() map. COMPLEX_KEY_HASHED layout requires a tuple key.
    dictGet('default.regionToShard', 'shardID', tuple(dc_name))
);
