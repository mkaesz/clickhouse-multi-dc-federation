-- Tier 3: Global distributed table (fan-out across all 3 DCs)
-- Run in MUC. Identical logic runs in FRA and HAM with only ON CLUSTER changed.
-- Requires test_local to already exist in FRA, MUC, and HAM before this runs,
-- and requires the federated_dcs remote_servers definition (3 shards: FRA/MUC/HAM)
-- to already be deployed to this node's config.d/.

CREATE TABLE default.dist_test_global ON CLUSTER 'muc_local'
AS default.test_local
ENGINE = Distributed(
    'federated_dcs',
    default,
    test_local,
    transform(dc_name, ['FRA', 'MUC', 'HAM'], [0, 1, 2], 0)
);
