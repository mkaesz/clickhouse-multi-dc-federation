# ClickHouse Multi-DC Federation — FRA / MUC / HAM

Three independent ClickHouse clusters — one per DC (FRA, MUC, HAM) — each with
its own external Keeper and no shared storage. Cross-DC access is via
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
    - [Shard pruning and optimize_skip_unused_shards](#shard-pruning-and-optimize_skip_unused_shards)

---

## Architecture

```
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│  kind cluster            │   │  kind cluster            │   │  kind cluster            │
│  ...demo-fra             │   │  ...demo-muc             │   │  ...demo-ham             │
│                          │   │                          │   │                          │
│  ns: fra                 │   │  ns: muc                 │   │  ns: ham                 │
│  ┌────────────────────┐  │   │  ┌────────────────────┐  │   │  ┌────────────────────┐  │
│  │ fra-keeper-0       │  │   │  │ muc-keeper-0       │  │   │  │ ham-keeper-0       │  │
│  │ (ClickHouseKeeper) │  │   │  │ (ClickHouseKeeper) │  │   │  │ (ClickHouseKeeper) │  │
│  └────────┬───────────┘  │   │  └────────┬───────────┘  │   │  └────────┬───────────┘  │
│           │ ZooKeeper    │   │           │ ZooKeeper    │   │           │ ZooKeeper    │
│  ┌────────▼───────────┐  │   │  ┌────────▼───────────┐  │   │  ┌────────▼───────────┐  │
│  │ fra-shard-0-0      │  │   │  │ muc-shard-0-0      │  │   │  │ ham-shard-0-0      │  │
│  │ (ClickHouse Helm)  │  │   │  │ (ClickHouse Helm)  │  │   │  │ (ClickHouse Helm)  │  │
│  └────────────────────┘  │   │  └────────────────────┘  │   │  └────────────────────┘  │
│  NodePort 30901 (TCP)    │   │  NodePort 30902 (TCP)    │   │  NodePort 30903 (TCP)    │
│  NodePort 30801 (HTTP)   │   │  NodePort 30802 (HTTP)   │   │  NodePort 30803 (HTTP)   │
└──────────────────────────┘   └──────────────────────────┘   └──────────────────────────┘
         │                                  │                                  │
         └──────────── federated_dcs: node-IP:NodePort cross-cluster TCP ──────┘
```

All three kind clusters share the Docker/Podman `kind` network. Cross-DC
queries route from a CH pod through its node (via kube-proxy masquerade) to
the target DC's NodePort. The `federated_dcs` remote_servers config is patched
with real node IPs after clusters are up.

**Host port mapping:**

| DC  | HTTP            | Native TCP      |
|-----|-----------------|-----------------|
| FRA | localhost:8801  | localhost:9801  |
| MUC | localhost:8802  | localhost:9802  |
| HAM | localhost:8803  | localhost:9803  |

---

## Schema tiers

| Tier | Table | Engine | Scope |
|------|-------|--------|-------|
| 1 | `test_local` | `ReplicatedMergeTree` | Physical data, per-DC |
| 2 | `dist_test_regional` | `Distributed('{dc}_local', …)` | Fan-out within one DC |
| 3 | `dist_test_global` | `Distributed('federated_dcs', …)` | Fan-out across all 3 DCs |

`dist_test_global` shards on `dc_name` via `transform()`:
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
└── poc/                                           # Local Kubernetes POC
    ├── setup.sh                                   # ← single entry point
    ├── teardown.sh
    ├── kind-fra.yaml                              # kind cluster: clickhouse-multi-dc-federation-demo-fra
    ├── kind-muc.yaml                              # kind cluster: clickhouse-multi-dc-federation-demo-muc
    ├── kind-ham.yaml                              # kind cluster: clickhouse-multi-dc-federation-demo-ham
    ├── manifests/
    │   ├── fra/
    │   │   ├── 00-namespace.yaml
    │   │   ├── 01-keeper.yaml                     # Keeper ConfigMap + headless Service + StatefulSet
    │   │   └── 02-nodeport.yaml                   # NodePort for host and cross-cluster access
    │   ├── muc/  (same)
    │   └── ham/  (same)
    ├── helm/
    │   ├── fra/values.yaml                        # ClickHouse Helm values (local cluster only)
    │   ├── muc/values.yaml
    │   └── ham/values.yaml
    └── scripts/
        ├── wait-for-pods.sh
        ├── patch-federation.sh                    # Discovers node IPs, injects federated_dcs
        ├── apply-schemas.sh                       # SQL in correct order
        └── verify.sh                              # Inserts + cross-DC queries + RBAC check
```

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker **or** Podman | Docker 20+ / Podman 4.3+ | see below |
| kind | 0.20+ | `brew install kind` |
| kubectl | 1.28+ | `brew install kubectl` |
| Helm | 3.12+ | `brew install helm` |
| clickhouse-client | any | `brew install clickhouse` (optional, for local queries) |

**Docker:**
```bash
# macOS / Windows: Docker Desktop  https://docs.docker.com/get-docker/
docker info
```

**Podman (alternative to Docker):**
```bash
# macOS
brew install podman
podman machine init
podman machine start

# Linux (rootless)
# Install via your distro's package manager, then:
systemctl --user enable --now podman.socket
# Ensure cgroup v2 is enabled: cat /sys/fs/cgroup/cgroup.controllers

# Verify
podman info
```

`setup.sh` auto-detects which runtime is running and sets
`KIND_EXPERIMENTAL_PROVIDER=podman` for kind automatically — no manual
configuration required.

Verify all tools:
```bash
kind version
kubectl version --client
helm version
docker info   # or: podman info
```

---

## Quick start

```bash
# Clone / cd into the repo root
cd /path/to/clickhouse-multi-dc-federation

# Full setup: creates 3 clusters, deploys keepers, installs ClickHouse,
# patches federation config, applies schemas
bash poc/setup.sh
```

Total time: ~8–12 minutes on first run (dominated by pulling 3× CH + 3× Keeper
images in parallel across three kind clusters).

When the script finishes:
```
   FRA  HTTP: http://localhost:8801    TCP: clickhouse-client --host localhost --port 9801
   MUC  HTTP: http://localhost:8802    TCP: clickhouse-client --host localhost --port 9802
   HAM  HTTP: http://localhost:8803    TCP: clickhouse-client --host localhost --port 9803
```

Run the full verification suite:
```bash
bash poc/scripts/verify.sh
```

---

## What setup.sh does

`setup.sh` runs these steps in order:

### 1. Prerequisite check
Verifies `kind`, `kubectl`, and `helm` are on `$PATH`, then calls
`detect_runtime()` which tries Docker first, then Podman. If Podman is
selected, `KIND_EXPERIMENTAL_PROVIDER=podman` is exported for the rest of the
script so every subsequent `kind` command uses the correct backend.

### 2. Create 3 kind clusters
Creates one cluster per DC from the per-DC config files:

```bash
kind create cluster --config poc/kind-fra.yaml   # clickhouse-multi-dc-federation-demo-fra
kind create cluster --config poc/kind-muc.yaml   # clickhouse-multi-dc-federation-demo-muc
kind create cluster --config poc/kind-ham.yaml   # clickhouse-multi-dc-federation-demo-ham
```

Each cluster is a single-node (control-plane only, taint removed via
`nodeRegistration.taints: []`) with NodePort mappings for host access.
Skip if a cluster already exists.

### 3. Namespaces
Creates namespace `fra`, `muc`, or `ham` inside each respective cluster.

### 4. External Keepers
Applies `poc/manifests/{dc}/01-keeper.yaml` to the matching cluster. Each
manifest contains:

- **ConfigMap** (`{dc}-keeper-config`): `keeper_config.xml` with
  `<listen_host>0.0.0.0</listen_host>`, `tcp_port 2181`, and a single-node
  `raft_configuration` pointing to `localhost:9234` (avoids DNS bootstrap race).
- **Service** (`{dc}-keeper`, headless): provides in-cluster DNS
  `{dc}-keeper-0.{dc}-keeper.{dc}.svc.cluster.local`.
- **StatefulSet** (`{dc}-keeper`): one pod running
  `clickhouse/clickhouse-keeper:latest` with an explicit
  `--config-file` arg, a `startupProbe` (300 s window), and readiness/liveness
  probes on `tcpSocket:2181`.

Waits for all three Keeper pods to pass the readiness probe.

### 5. ClickHouse via Helm
Adds the ClickHouse Helm repo and installs one release per cluster:

```bash
helm install fra clickhouse/clickhouse \
  --kube-context kind-clickhouse-multi-dc-federation-demo-fra \
  --namespace fra -f poc/helm/fra/values.yaml --wait
# same for muc and ham
```

Key settings in each `values.yaml`:

| Key | Value | Effect |
|-----|-------|--------|
| `fullnameOverride` | `fra` / `muc` / `ham` | Predictable StatefulSet/service names |
| `shards` / `replicaCount` | `1` / `1` | Single shard, single replica per DC |
| `clusterName` | `fra_local` etc. | ClickHouse `{cluster}` macro |
| `keeper.enabled` | `false` | Use external Keeper (step 4) |
| `extraConfigFiles.zookeeper.xml` | DC-local Keeper FQDN | Keeper connection |
| `extraConfigFiles.remote_servers.xml` | Local cluster only (no `federated_dcs` yet) | Patched in step 7 |
| `extraConfigFiles.listen.xml` | `0.0.0.0` | Accept cross-cluster connections |
| `extraConfigFiles.users_network.xml` | `::/0` | Allow `default` user from any IP |

NodePort services are applied after Helm install to expose each DC on the host.

### 6. Naming verification
Prints actual pod and service names from each cluster so you can confirm the
FQDNs in `remote_servers.xml` are correct before proceeding.

### 7. Patch federated_dcs (`patch-federation.sh`)
Discovers the InternalIP of each cluster's kind node, generates a
`federated_dcs` remote_servers block with those IPs + the DC's NodePort, and
runs `helm upgrade --reuse-values -f /tmp/patch.yaml` on each cluster:

```
FRA node IP: 172.18.0.2  → used as shard 0 in federated_dcs (port 30901)
MUC node IP: 172.18.0.3  → used as shard 1 in federated_dcs (port 30902)
HAM node IP: 172.18.0.4  → used as shard 2 in federated_dcs (port 30903)
```

Followed by `SYSTEM RELOAD CONFIG` on each CH pod.

**Why NodePort IPs work across clusters:** all kind nodes share the Docker/
Podman `kind` network. A pod in cluster FRA that connects to
`MUC_NODE_IP:30902` has its traffic masqueraded through the FRA node (via
kindnet NAT), which then reaches the MUC node on the shared kind network.
kube-proxy on the MUC node forwards the NodePort to the MUC CH pod.

### 8. Schema deployment
Runs `poc/scripts/apply-schemas.sh` with `--context kind-clickhouse-multi-dc-federation-demo-{dc}` on every kubectl/helm call:

```
Tier 1 (per DC): 01_tier1_local/{dc}_test_local.sql
Tier 2 (per DC): 02_tier2_regional/{dc}_dist_test_regional.sql
Tier 3 (per DC): 03_tier3_global/{dc}_dist_test_global.sql   ← needs Tier 1 in all DCs first
RBAC  (per DC):  04_rbac/roles_and_grants.sql
```

---

## Verifying pod naming

The Helm chart produces names from `fullnameOverride`. The assumed naming is:

| Object | Expected name (FRA example) |
|--------|------------------------------|
| StatefulSet | `fra-shard-0` |
| Pod | `fra-shard-0-0` |
| Headless service | `fra-headless` |
| Pod FQDN (in-cluster) | `fra-shard-0-0.fra-headless.fra.svc.cluster.local` |

Check actual names after Helm install:
```bash
kubectl get pods,svc --context kind-clickhouse-multi-dc-federation-demo-fra -n fra
kubectl get pods,svc --context kind-clickhouse-multi-dc-federation-demo-muc -n muc
kubectl get pods,svc --context kind-clickhouse-multi-dc-federation-demo-ham -n ham
```

If the headless service name differs (e.g. `fra` instead of `fra-headless`),
update `extraConfigFiles.remote_servers.xml` in `poc/helm/{dc}/values.yaml`,
then re-run:

```bash
helm upgrade fra clickhouse/clickhouse \
  --kube-context kind-clickhouse-multi-dc-federation-demo-fra \
  --namespace fra -f poc/helm/fra/values.yaml --wait

kubectl exec --context kind-clickhouse-multi-dc-federation-demo-fra \
  -n fra fra-shard-0-0 -- clickhouse-client --query "SYSTEM RELOAD CONFIG"
```

---

## Running queries

### Via clickhouse-client on the host

```bash
clickhouse-client --host localhost --port 9801   # FRA
clickhouse-client --host localhost --port 9802   # MUC
clickhouse-client --host localhost --port 9803   # HAM
```

### Via HTTP on the host

```bash
curl http://localhost:8801/ping   # health check
curl http://localhost:8802/ping
curl http://localhost:8803/ping

# Cross-DC row count
curl 'http://localhost:8801/?query=SELECT+dc_name,count()+FROM+default.dist_test_global+GROUP+BY+dc_name+ORDER+BY+dc_name'
```

### Via kubectl exec

```bash
kubectl exec --context kind-clickhouse-multi-dc-federation-demo-fra \
  -n fra fra-shard-0-0 -- clickhouse-client --query "SELECT 1"
```

### Common queries

**Insert into a DC (regional table only — never the global one):**
```sql
-- Connect to MUC (localhost:9802), then:
INSERT INTO default.dist_test_regional (id, event_time, payload)
VALUES (100, now(), 'hello from MUC');
```

**Read from one DC:**
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

**Single-DC read with shard pruning (touches only MUC's shard):**
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

> **`optimize_skip_unused_shards` must be explicit.**
> Without this setting every query fans out to all three DC shards regardless
> of the WHERE clause. Add it to individual queries, or set it once as a
> per-user default so application code never needs to carry it:
> ```sql
> ALTER USER default SETTINGS optimize_skip_unused_shards = 1;
> ```
> See [Design notes → Shard pruning](#shard-pruning-and-optimize_skip_unused_shards)
> for the full explanation and all three configuration options.

**Confirm shard pruning via EXPLAIN PIPELINE (not EXPLAIN):**
```sql
-- EXPLAIN PIPELINE shows the actual execution path; EXPLAIN shows the logical
-- plan which looks identical with or without pruning.
EXPLAIN PIPELINE SELECT * FROM default.dist_test_global
WHERE dc_name = 'HAM'
SETTINGS optimize_skip_unused_shards = 1;
-- FRA (local): ReadFromMergeTree  → local read, zero network hop
-- MUC/HAM:     ReadFromRemote     → goes to the matching DC's NodePort
-- With dc_name = 'HAM' + pruning: only ReadFromRemote (FRA and MUC not contacted)
```

**Verify RBAC (should fail with Code 497):**
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

Deletes all three kind clusters:
```
kind delete cluster --name clickhouse-multi-dc-federation-demo-fra
kind delete cluster --name clickhouse-multi-dc-federation-demo-muc
kind delete cluster --name clickhouse-multi-dc-federation-demo-ham
```

All Helm releases, namespaces, and data are gone. No persistent storage, so
nothing remains on disk.

---

## Design notes

**Three separate kind clusters**
Each DC runs in its own kind cluster, giving fully independent Kubernetes API
servers, CNI networks, and Keeper ensembles — closer to real DC isolation than
a single cluster with three namespaces. Cross-cluster communication uses
NodePort services on the shared Docker/Podman `kind` network; no MetalLB or
manual routing is required because kind places all cluster nodes on the same
bridge network by default.

**Single-node Keeper with `localhost` raft hostname**
Each DC uses a one-node Keeper. The `raft_configuration` uses `hostname:
localhost` to avoid a DNS bootstrap race (the pod's own headless-service DNS
entry isn't available until after the pod starts). For production, use a
3-node ensemble and replace `localhost` with each node's FQDN.

**Single replica per DC**
`replicaCount: 1` means `ReplicatedMergeTree` behaves like `MergeTree` — no
intra-DC replication. Increment `replicaCount` in `values.yaml` and re-run
`helm upgrade` to add replicas.

**Dynamic federation patching**
`federated_dcs` remote_servers are not in the committed `values.yaml` files
because the kind node IPs are not known until the clusters exist.
`patch-federation.sh` discovers IPs at runtime and injects them via
`helm upgrade --reuse-values`. Running `setup.sh` again is idempotent: the
patch step overwrites with current IPs.

**`transform()` shard mapping**
```sql
transform(dc_name, ['FRA', 'MUC', 'HAM'], [0, 1, 2], 0)
```
The shard order must match `federated_dcs` in `remote_servers.xml`
(FRA=shard 0, MUC=shard 1, HAM=shard 2). Unknown `dc_name` values fall back
to shard 0 (FRA).

**Shard pruning and `optimize_skip_unused_shards`**
Without this setting ClickHouse fans out every `dist_test_global` query to all
three DC shards and applies the WHERE filter only after receiving results.
The setting must be explicitly enabled; there are three ways to do it:

| Option | How | Scope |
|--------|-----|-------|
| Per-query | `SETTINGS optimize_skip_unused_shards = 1` at end of SQL | Single query |
| Per-role/user | `ALTER ROLE app_reader SETTINGS optimize_skip_unused_shards = 1` | All queries from users with that role |
| Server profile | Add to **`extraUsersConfig`** in the ClickHouseCluster CR (see below) | All users on that profile |

> **Note on the built-in `default` user:** this user is defined in the
> read-only `users_xml` config and cannot be altered via SQL (`ALTER USER`
> returns `ACCESS_STORAGE_READONLY`). Use the server profile approach instead.
> Profile settings must go in **`extraUsersConfig`** (writes to `users.d/`),
> not `extraConfig` (which writes to `config.d/` and is ignored for profiles):
> ```bash
> kubectl patch clickhousecluster fra -n fra --type merge --patch '{
>   "spec": {"settings": {"extraUsersConfig": {
>     "profiles": {"default": {"optimize_skip_unused_shards": 1}}
>   }}}
> }'
> ```
> This is already applied in the POC — all three DCs have the setting active.

The role-level `ALTER ROLE` is included in `schemas/04_rbac/roles_and_grants.sql`
and is applied automatically by `apply-schemas.sh`. The server profile approach
is preferred for production because it applies uniformly to all users without
relying on role assignment.

Pruning only activates for **direct equality or IN predicates on the sharding
column** (`dc_name` here). `!=`, range comparisons, and expressions on the
column do not prune — all shards are contacted even with the setting on.

To verify pruning is working, use `EXPLAIN PIPELINE` (not `EXPLAIN`):
`EXPLAIN` shows the logical plan before execution-time optimisation and looks
identical regardless of the setting. `EXPLAIN PIPELINE` shows the physical
plan: a pruned local query shows `ReadFromMergeTree`; a pruned remote-only
query shows `ReadFromRemote`; an unpruned query shows `Union` of both.
Alternatively, run `SYSTEM FLUSH LOGS` then check `system.query_log.read_rows`
— a pruned single-DC query reads fewer rows than an unpruned full-scan of the
same data.

**No TLS in the POC**
Production config (`schemas/00_config_reference/`) uses `<port>9440</port>
<secure>1</secure>`. The POC uses plain `9000` / `9001-9003` NodePorts. Do not
use the POC config as a template for production.
