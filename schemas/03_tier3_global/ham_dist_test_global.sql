-- Tier 3: Global distributed table (fan-out across all 3 DCs)
-- Requires dist_test_regional to already exist in FRA, MUC, and HAM, and requires the
-- federated_dcs remote_servers definition (3 shards: FRA/MUC/HAM) to be present.

CREATE TABLE IF NOT EXISTS default.dist_test_global ON CLUSTER 'default'
AS default.test_local
ENGINE = Distributed(
    'federated_dcs',
    default,
    dist_test_regional,
    transform(dc_name, ['FRA', 'MUC', 'HAM'], [0, 1, 2], 0)
);
