-- RBAC: run identically in FRA, MUC, and HAM.
-- Users/roles are NOT shared across DCs (no cross-DC Keeper/RBAC storage),
-- so this file must be executed once per DC against that DC's own cluster.

CREATE ROLE IF NOT EXISTS app_writer;
CREATE ROLE IF NOT EXISTS app_reader;

-- Writers: local DC only. All writes go directly to the local MergeTree
-- (test_local); writers never INSERT through a Distributed table.
-- Writers never get a grant on dist_test_global.
GRANT INSERT, SELECT ON default.test_local TO app_writer;
GRANT SELECT ON default.dist_test_regional TO app_writer;

-- Readers: cross-DC fan-out queries only, no writes anywhere.
GRANT SELECT ON default.dist_test_global TO app_reader;
GRANT SELECT ON default.dist_test_regional TO app_reader;

-- Safeguard: explicitly ensure nobody can INSERT into a Distributed table,
-- even if a future grant is added by mistake. All writes must target the
-- local MergeTree (test_local) only.
REVOKE INSERT ON default.dist_test_regional FROM app_writer, app_reader;
REVOKE INSERT ON default.dist_test_global FROM app_writer, app_reader;

-- Shard pruning: enable optimize_skip_unused_shards by default for all roles
-- so application queries don't need to carry the SETTINGS clause.
-- Without this, every dist_test_global query fans out to all 3 DC shards
-- regardless of the WHERE clause.
ALTER ROLE app_writer SETTINGS optimize_skip_unused_shards = 1;
ALTER ROLE app_reader SETTINGS optimize_skip_unused_shards = 1;
-- NOTE: the built-in 'default' user is defined in the read-only users_xml
-- config and cannot be altered via SQL (returns ACCESS_STORAGE_READONLY).
-- Set optimize_skip_unused_shards for it via the ClickHouseCluster CR's
-- extraUsersConfig (NOT extraConfig -- that writes to config.d/ which is
-- ignored for profile settings; extraUsersConfig writes to users.d/):
--   spec.settings.extraUsersConfig.profiles.default.optimize_skip_unused_shards: 1
-- This is already patched on all 3 DCs in the demo.

-- Assign roles to actual users (adjust usernames as needed):
-- GRANT app_writer TO ingest_user;
-- GRANT app_reader TO bi_user;
