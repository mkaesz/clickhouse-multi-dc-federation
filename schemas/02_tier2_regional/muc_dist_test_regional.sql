-- Tier 2: Regional distributed table (fan-out across shards inside MUC)
-- Currently a no-op since MUC is a single shard today; exists so MUC can grow
-- to multiple shards later without any application-level query changes.

CREATE TABLE IF NOT EXISTS default.dist_test_regional ON CLUSTER 'default'
AS default.test_local
ENGINE = Distributed('default', default, test_local, rand());
