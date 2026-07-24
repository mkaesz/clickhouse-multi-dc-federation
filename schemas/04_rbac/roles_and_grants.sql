-- RBAC: run identically in FRA, MUC, and HAM.
-- Users/roles are NOT shared across DCs (no cross-DC Keeper/RBAC storage),
-- so this file must be executed once per DC against that DC's own cluster.

CREATE ROLE IF NOT EXISTS app_writer;
CREATE ROLE IF NOT EXISTS app_reader;

-- Writers: local DC only, via the regional distributed table.
-- Writers never get a grant on dist_test_global.
GRANT INSERT, SELECT ON default.dist_test_regional TO app_writer;
GRANT SELECT ON default.test_local TO app_writer;

-- Readers: cross-DC fan-out queries only, no writes anywhere.
GRANT SELECT ON default.dist_test_global TO app_reader;
GRANT SELECT ON default.dist_test_regional TO app_reader;

-- Safeguard: explicitly ensure nobody can INSERT into the global table,
-- even if a future grant is added by mistake.
REVOKE INSERT ON default.dist_test_global FROM app_writer, app_reader;

-- Assign roles to actual users (adjust usernames as needed):
-- GRANT app_writer TO ingest_user;
-- GRANT app_reader TO bi_user;
