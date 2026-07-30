-- RBAC: run identically in FRA, MUC, and HAM.
-- Users/roles are NOT shared across DCs (no cross-DC Keeper/RBAC storage),
-- so this file must be executed once per DC against that DC's own cluster.

CREATE ROLE IF NOT EXISTS app_writer;
CREATE ROLE IF NOT EXISTS app_reader;

-- Writers: local DC only. All writes go directly to the local MergeTree
-- (otel_local); writers never INSERT through a Distributed table.
-- Writers never get a grant on otel_global.
GRANT INSERT, SELECT ON default.otel_local TO app_writer;
GRANT SELECT ON default.otel_regional TO app_writer;

-- Readers: cross-DC fan-out queries only, no writes anywhere.
-- Reading otel_global fans out down the whole chain
-- (otel_global -> otel_regional -> otel_local), and ClickHouse checks SELECT
-- privilege on each underlying table, so the reader needs SELECT on all three
-- -- otel_global alone is not enough.
GRANT SELECT ON default.otel_global TO app_reader;
GRANT SELECT ON default.otel_regional TO app_reader;
GRANT SELECT ON default.otel_local TO app_reader;

-- Safeguard: explicitly ensure nobody can INSERT into a Distributed table,
-- even if a future grant is added by mistake. All writes must target the
-- local MergeTree (otel_local) only.
REVOKE INSERT ON default.otel_regional FROM app_writer, app_reader;
REVOKE INSERT ON default.otel_global FROM app_writer, app_reader;

-- Shard pruning: enable it by default for all roles so application queries
-- don't need to carry a SETTINGS clause. BOTH settings are required:
-- otel_global's sharding key is dictGet(...), which ClickHouse treats as
-- non-deterministic, so optimize_skip_unused_shards alone silently refuses
-- to prune -- allow_nondeterministic_optimize_skip_unused_shards unlocks it.
-- Without pruning, every otel_global query fans out to all 3 DC shards
-- regardless of the WHERE clause.
ALTER ROLE app_writer SETTINGS
    optimize_skip_unused_shards = 1,
    allow_nondeterministic_optimize_skip_unused_shards = 1;
ALTER ROLE app_reader SETTINGS
    optimize_skip_unused_shards = 1,
    allow_nondeterministic_optimize_skip_unused_shards = 1;
-- NOTE: the built-in 'default' user is defined in the read-only users_xml
-- config and cannot be altered via SQL (returns ACCESS_STORAGE_READONLY).
-- Both settings are therefore applied to the `default` profile via each
-- ClickHouseCluster CR's extraUsersConfig (NOT extraConfig -- that writes to
-- config.d/ which is ignored for profile settings; extraUsersConfig writes to
-- the users realm):
--   spec.settings.extraUsersConfig.profiles.default:
--     optimize_skip_unused_shards: 1
--     allow_nondeterministic_optimize_skip_unused_shards: 1
-- This is encoded in manifests/{fra,muc,ham}/01-clickhouse-crs.yaml, so a
-- fresh `bash setup.sh` brings all 3 DCs up with pruning already on.

-- Assign roles to actual users (adjust usernames as needed):
-- GRANT app_writer TO ingest_user;
-- GRANT app_reader TO bi_user;
