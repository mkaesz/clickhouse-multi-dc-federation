# FRA / MUC / HAM ClickHouse Geo Schema POC

Three independent ClickHouse clusters — one per DC (FRA, MUC, HAM) — each with
its own external Keeper ensemble and no shared storage. Cross-DC access is via
query-level federation (`remote_servers`) only; no replication or Raft ever
crosses a DC boundary.

---

## Table of contents

1. [Architecture](#architecture)
2. [Schema tiers](#schema-tiers)
3. [Repository layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Quick start](#quick-start)
6. [What setup.sh does](#what-setupsh-does)
7. [Verifying pod naming](#verifying-pod-naming)
8. [Running queries](#running-queries)
9. [Teardown](#teardown)
10. [Design notes](#design-notes)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  kind cluster "geo-poc"  (single cluster, 3 namespaces = 3 DCs)     │
│                                                                     │
│  ┌───────────────┐   ┌───────────────┐   ┌───────────────┐         │
│  │  ns: fra      │   │  ns: muc      │   │  ns: ham      │         │
│  │               │   │               │   │               │         │
│  │ fra-keeper-0  │   │ muc-keeper-0  │   │ ham-keeper-0  │         │
│  │  (Keeper SS)  │   │  (Keeper SS)  │   │  (Keeper SS)  │         │
│  │       ↑       │   │       ↑       │   │       ↑       │         │
│  │ fra-shard-0-0 │   │ muc-shard-0-0 │   │ ham-shard-0-0 │         │
│  │  (CH server)  │   │  (CH server)  │   │  (CH server)  │         │
│  └───────────────┘   └───────────────┘   └───────────────┘         │
│         ↑                   ↑                   ↑                   │
│   ← federated_dcs: 3 shards, cross-namespace TCP →                  │
└─────────────────────────────────────────────────────────────────────┘
```

Each DC is a single ClickHouse node (1 shard, 1 replica) backed by its own
single-node Keeper. Cross-DC queries go through the `federated_dcs`
`remote_servers` cluster, which wires all three DCs together as three shards.

**Host port mapping** (via kind NodePort):

| DC  | HTTP          | Native TCP    |
|-----|---------------|---------------|
| FRA | localhost:8801 | localhost:9801 |
| MUC | localhost:8802 | localhost:9802 |
| HAM | localhost:8803 | localhost:9803 |

---

## Schema tiers

| Tier | Table | Engine | Scope |
|------|-------|--------|-------|
| 1 | `test_local` | `ReplicatedMergeTree` | Physical data, per-DC |
| 2 | `dist_test_regional` | `Distributed('*_local', …)` | Fan-out within one DC |
| 3 | `dist_test_global` | `Distributed('federated_dcs', …)` | Fan-out across all 3 DCs |

`dist_test_global` shards on `dc_name` using `transform()`:
`FRA→shard 0`, `MUC→shard 1`, `HAM→shard 2`.

**RBAC roles:**

| Role | Permissions |
|------|-------------|
| `app_writer` | `INSERT, SELECT` on `dist_test_regional` and `test_local` |
| `app_reader` | `SELECT` on `dist_test_global` and `dist_test_regional` |

Writers can never `INSERT` into `dist_test_global` — enforced by SQL `REVOKE`.

---

## Repository layout

```
.
├── schemas/
│   ├── 00_config_reference/
│   │   └── federated_dcs_remote_servers.xml   # Reference XML (production FQDNs)
│   ├── 01_tier1_local/
│   │   ├── fra_test_local.sql
│   │   ├── muc_test_local.sql
│   │   └── ham_test_local.sql
│   ├── 02_tier2_regional/
│   │   ├── fra_dist_test_regional.sql
│   │   ├── muc_dist_test_regional.sql
│   │   └── ham_dist_test_regional.sql
│   ├── 03_tier3_global/
│   │   ├── fra_dist_test_global.sql
│   │   ├── muc_dist_test_global.sql
│   │   └── ham_dist_test_global.sql
│   ├── 04_rbac/
│   │   └── roles_and_grants.sql
│   └── 05_verification/
│       └── sanity_checks.sql
├── example_queries.txt
└── poc/                                       # Local Kubernetes POC
    ├── setup.sh                               # ← single entry point
    ├── teardown.sh
    ├── kind-config.yaml
    ├── manifests/
    │   ├── fra/
    │   │   ├── 00-namespace.yaml
    │   │   ├── 01-keeper.yaml                 # Keeper ConfigMap + Service + StatefulSet
    │   │   └── 02-nodeport.yaml               # NodePort for host access
    │   ├── muc/  (same)
    │   └── ham/  (same)
    ├── helm/
    │   ├── fra/values.yaml                    # ClickHouse Helm values
    │   ├── muc/values.yaml
    │   └── ham/values.yaml
    └── scripts/
        ├── wait-for-pods.sh
        ├── apply-schemas.sh                   # SQL in correct order
        └── verify.sh                          # Inserts + cross-DC queries + RBAC check
```

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker | 20+ | https://docs.docker.com/get-docker/ |
| kind | 0.20+ | `brew install kind` |
| kubectl | 1.28+ | `brew install kubectl` |
| Helm | 3.12+ | `brew install helm` |
| clickhouse-client | any | `brew install clickhouse` (optional, for local queries) |

Verify:
```bash
kind version
kubectl version --client
helm version
docker info
```

---

## Quick start

```bash
# Clone / cd into the repo root
cd /path/to/geo-poc

# Full setup: creates cluster, deploys keepers, installs ClickHouse, applies schemas
bash poc/setup.sh
```

Total time: ~5–8 minutes (dominated by image pulls on first run).

When the script finishes it prints:
```
   FRA HTTP: http://localhost:8801   native TCP: localhost:9801
   MUC HTTP: http://localhost:8802   native TCP: localhost:9802
   HAM HTTP: http://localhost:8803   native TCP: localhost:9803
```

Run the verification suite:
```bash
bash poc/scripts/verify.sh
```

---

## What setup.sh does

`setup.sh` runs these steps in order:

### 1. Prerequisite check
Verifies `kind`, `kubectl`, `helm`, and `docker` are on `$PATH`.

### 2. kind cluster
Creates a single kind cluster named `geo-poc` from `poc/kind-config.yaml`.
The cluster has 1 control-plane node and 2 workers. The control-plane has
six NodePort mappings so all three DCs are reachable from the host.

```bash
kind create cluster --config poc/kind-config.yaml
```

Skip if the cluster already exists.

### 3. Namespaces
Creates `fra`, `muc`, `ham` from `poc/manifests/{dc}/00-namespace.yaml`.

### 4. External Keepers
Applies `poc/manifests/{dc}/01-keeper.yaml` for each DC. Each manifest
contains three Kubernetes objects:

- **ConfigMap** (`{dc}-keeper-config`): injects `keeper_config.xml` into
  `/etc/clickhouse-keeper/keeper_config.xml`. Configures a single-node
  Keeper listening on port 2181 (client) and 9234 (Raft).
- **Service** (`{dc}-keeper`, headless): provides stable DNS for the pod:
  `{dc}-keeper-0.{dc}-keeper.{dc}.svc.cluster.local`.
- **StatefulSet** (`{dc}-keeper`): one pod running
  `clickhouse/clickhouse-keeper:25.3`.

Waits for all three Keeper pods to pass their `tcpSocket:2181` readiness
probe before proceeding.

### 5. ClickHouse via Helm
Adds the ClickHouse Helm repo and installs one release per DC:

```bash
helm repo add clickhouse https://charts.clickhouse.com
helm install fra clickhouse/clickhouse -n fra -f poc/helm/fra/values.yaml --wait
helm install muc clickhouse/clickhouse -n muc -f poc/helm/muc/values.yaml --wait
helm install ham clickhouse/clickhouse -n ham -f poc/helm/ham/values.yaml --wait
```

Key settings in each `values.yaml`:

| Key | Value | Effect |
|-----|-------|--------|
| `fullnameOverride` | `fra` / `muc` / `ham` | Predictable StatefulSet names |
| `shards` | `1` | Single shard per DC |
| `replicaCount` | `1` | Single replica (POC only) |
| `clusterName` | `fra_local` etc. | ClickHouse `{cluster}` macro |
| `keeper.enabled` | `false` | Disable built-in keeper |
| `extraConfigFiles.zookeeper.xml` | DC-local keeper FQDN | Keeper connection |
| `extraConfigFiles.remote_servers.xml` | `fra_local` + `federated_dcs` | Cluster definitions |
| `extraConfigFiles.listen.xml` | `0.0.0.0` | Accept remote connections |
| `extraConfigFiles.users_network.xml` | `::/0` | Allow intercluster default user |

Then applies `poc/manifests/{dc}/02-nodeport.yaml` to expose each DC on the
host via the NodePort mapped in `kind-config.yaml`.

### 6. Naming verification
Prints the actual pod and service names created by the chart. Use this to
confirm the FQDNs in `remote_servers.xml` are correct (see
[Verifying pod naming](#verifying-pod-naming)).

### 7. Schema deployment
Calls `poc/scripts/apply-schemas.sh`, which discovers CH pods dynamically
and runs SQL files in this order:

```
Tier 1 (per DC): 01_tier1_local/{dc}_test_local.sql
Tier 2 (per DC): 02_tier2_regional/{dc}_dist_test_regional.sql
Tier 3 (per DC): 03_tier3_global/{dc}_dist_test_global.sql   ← all DCs must have Tier 1 first
RBAC  (per DC):  04_rbac/roles_and_grants.sql
```

SQL is piped via `kubectl exec -i … clickhouse-client --multiquery`.

---

## Verifying pod naming

The Helm chart produces StatefulSet and Service names based on
`fullnameOverride`. The assumed naming (baked into `remote_servers.xml`) is:

| Object | Expected name |
|--------|--------------|
| StatefulSet | `fra-shard-0` |
| Pod | `fra-shard-0-0` |
| Headless service | `fra-headless` |
| Pod FQDN | `fra-shard-0-0.fra-headless.fra.svc.cluster.local` |

Check actual names after Helm install:
```bash
kubectl get pods,svc -n fra
kubectl get pods,svc -n muc
kubectl get pods,svc -n ham
```

If the names differ (e.g. the headless service is `fra` not `fra-headless`),
update the `extraConfigFiles.remote_servers.xml` block in each
`poc/helm/{dc}/values.yaml`, then:

```bash
helm upgrade fra clickhouse/clickhouse -n fra -f poc/helm/fra/values.yaml --wait
helm upgrade muc clickhouse/clickhouse -n muc -f poc/helm/muc/values.yaml --wait
helm upgrade ham clickhouse/clickhouse -n ham -f poc/helm/ham/values.yaml --wait

# Reload config on each node (no restart needed)
kubectl exec -n fra fra-shard-0-0 -- clickhouse-client --query "SYSTEM RELOAD CONFIG"
kubectl exec -n muc muc-shard-0-0 -- clickhouse-client --query "SYSTEM RELOAD CONFIG"
kubectl exec -n ham ham-shard-0-0 -- clickhouse-client --query "SYSTEM RELOAD CONFIG"
```

---

## Running queries

### Via clickhouse-client on the host

```bash
# FRA
clickhouse-client --host localhost --port 9801

# MUC
clickhouse-client --host localhost --port 9802

# HAM
clickhouse-client --host localhost --port 9803
```

### Via HTTP on the host

```bash
# Health check
curl http://localhost:8801/ping
curl http://localhost:8802/ping
curl http://localhost:8803/ping

# Cross-DC row count
curl 'http://localhost:8801/?query=SELECT+dc_name,count()+FROM+default.dist_test_global+GROUP+BY+dc_name+ORDER+BY+dc_name'
```

### Via kubectl exec (inside the cluster)

```bash
kubectl exec -n fra fra-shard-0-0 -- clickhouse-client --query "SELECT 1"
```

### Common queries

**Insert into a DC (use the regional table, never the global one):**
```sql
-- Connect to MUC, then:
INSERT INTO default.dist_test_regional (id, event_time, payload)
VALUES (100, now(), 'hello from MUC');
```

**Read all rows from one DC:**
```sql
SELECT * FROM default.dist_test_regional ORDER BY event_time DESC LIMIT 20;
```

**Cross-DC aggregation:**
```sql
SELECT dc_name, count() AS rows
FROM default.dist_test_global
GROUP BY dc_name
ORDER BY dc_name;
```

**Single-DC read with shard pruning (queries only MUC's shard):**
```sql
SELECT *
FROM default.dist_test_global
WHERE dc_name = 'MUC'
ORDER BY event_time DESC
LIMIT 100
SETTINGS optimize_skip_unused_shards = 1;
```

**Multi-DC read with shard pruning (skips FRA):**
```sql
SELECT dc_name, count() AS errors
FROM default.dist_test_global
WHERE dc_name IN ('MUC', 'HAM')
  AND event_time >= now() - toIntervalHour(1)
GROUP BY ALL
ORDER BY ALL ASC
SETTINGS optimize_skip_unused_shards = 1;
```

**Confirm shard pruning (check EXPLAIN output for shard count):**
```sql
EXPLAIN SELECT * FROM default.dist_test_global
WHERE dc_name = 'HAM'
SETTINGS optimize_skip_unused_shards = 1;
-- Expected: 1 shard referenced, not 3
```

**Verify RBAC (as app_writer — should fail on the global table):**
```sql
INSERT INTO default.dist_test_global (id, event_time, payload, dc_name)
VALUES (9999, now(), 'should be rejected', 'FRA');
-- Expected: Code: 497. DB::Exception: Not enough privileges
```

See `example_queries.txt` for the complete annotated query set.

---

## Teardown

```bash
bash poc/teardown.sh
```

This deletes the entire kind cluster (`kind delete cluster --name geo-poc`).
All namespaces, Helm releases, and data are gone. There is no persistent
storage, so nothing remains on disk.

---

## Design notes

**Single kind cluster vs. three kind clusters**
Three separate kind clusters would more faithfully simulate DC isolation at
the network level, but cross-cluster communication in kind requires MetalLB
or manual route injection. Using one cluster with three namespaces keeps the
POC self-contained and still demonstrates all architectural properties:
separate Keeper ensembles, separate ClickHouse `ON CLUSTER` scopes, and
cross-namespace TCP federation.

**Single-node Keeper**
Each DC uses a one-node Keeper (no Raft quorum required for 1 node). For
production, use a 3-node Keeper ensemble per DC. The `raft_configuration`
block in `poc/manifests/{dc}/01-keeper.yaml` already shows the per-server
structure; add two more `<server>` entries and set `replicas: 3` in the
StatefulSet.

**Single replica per DC**
`replicaCount: 1` means ReplicatedMergeTree behaves like MergeTree — there
is no intra-DC replication. To add a second replica, increment
`replicaCount: 2` in `values.yaml` and re-run `helm upgrade`.

**`transform()` shard mapping**
The `dist_test_global` table uses:
```sql
transform(dc_name, ['FRA', 'MUC', 'HAM'], [0, 1, 2], 0)
```
This maps DC names to shard indices. The mapping **must** match the shard
order in `remote_servers.xml` (`federated_dcs`). If a `dc_name` value
outside `['FRA','MUC','HAM']` arrives, it falls back to shard 0 (FRA).

**`replace="1"` in remote_servers.xml**
The Helm chart may generate its own `remote_servers` block for the local
cluster. The `replace="1"` attribute on our `<remote_servers>` element
overwrites any prior definition, so the injected config always wins.

**No TLS in the POC**
Production config (`schemas/00_config_reference/federated_dcs_remote_servers.xml`)
uses `<port>9440</port><secure>1</secure>`. The POC uses plain `9000` since
kind does not have certificates provisioned. Do not use the POC config as a
template for production.
