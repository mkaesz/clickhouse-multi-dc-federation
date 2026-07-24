-- Tier 2: Regional distributed table (fan-out across shards inside FRA)
-- Currently a no-op since FRA is a single shard today; exists so FRA can grow
-- to multiple shards later without any application-level query changes.

CREATE TABLE default.dist_test_regional ON CLUSTER 'fra_local'
AS default.test_local
ENGINE = Distributed('fra_local', default, test_local, rand());
