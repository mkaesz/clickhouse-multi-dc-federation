-- Tier 2: Regional distributed table (fan-out across shards inside HAM)
-- Currently a no-op since HAM is a single shard today; exists so HAM can grow
-- to multiple shards later without any application-level query changes.

CREATE TABLE default.dist_test_regional ON CLUSTER 'default'
AS default.test_local
ENGINE = Distributed('default', default, test_local, rand());
