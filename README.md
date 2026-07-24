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
│  │ fra-keeper-0-0     │  │   │  │ muc-keeper-0-0     │  │   │  │ ham-keeper-0-0     │  │
│  │ (KeeperCluster CR) │  │   │  │ (KeeperCluster CR) │  │   │  │ (KeeperCluster CR) │  │
│  └────────┬───────────┘  │   │  └────────┬───────────┘  │   │  └────────┬───────────┘  │
│           │ (Keeper)     │   │           │ (Keeper)     │   │           │ (Keeper)     │
│  ┌────────▼───────────┐  │   │  ┌────────▼───────────┐  │   │  ┌────────▼───────────┐  │
│  │ fra-clickhouse-0-0-0│ │   │  │ muc-clickhouse-0-0-0│ │   │  │ ham-clickhouse-0-0-0│ │
│  │ (ClickHouseCluster)│  │   │  │ (ClickHouseCluster)│  │   │  │ (ClickHouseCluster)│  │
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

| DC  | HTTP            | Native TCP      | Native TCP (TLS) |
|-----|-----------------|-----------------|------------------|
| FRA | localhost:8801  | localhost:9801  | localhost:9841   |
| MUC | localhost:8802  | localhost:9802  | localhost:9842   |
| HAM | localhost:8803  | localhost:9803  | localhost:9843   |

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
├── setup.sh                                       # ← single entry point
├── teardown.sh
├── manifests/
│   ├── federated_dcs_remote_servers.xml           # Reference config (production FQDNs)
│   ├── fra/
│   │   ├── kind.yaml                              # kind cluster: clickhouse-multi-dc-federation-demo-fra
│   │   ├── 00-namespace.yaml
│   │   ├── 01-clickhouse-crs.yaml                 # KeeperCluster + ClickHouseCluster CRs
│   │   └── 02-nodeport.yaml                       # NodePort for host and cross-cluster access
│   ├── muc/  (same)
│   └── ham/  (same)
└── scripts/
    ├── wait-for-pods.sh
    ├── patch-federation.sh                        # Discovers node IPs, injects federated_dcs
    ├── setup-tls.sh                               # Generates certs, secrets, patches CRs for TLS
    ├── apply-schemas.sh                           # SQL in correct order
    └── verify.sh                                  # Inserts + cross-DC queries + RBAC check
```

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker | 20+ | [Docker Desktop](https://docs.docker.com/get-docker/) |
| kind | 0.20+ | `brew install kind` |
| kubectl | 1.28+ | `brew install kubectl` |
| Helm | 3.12+ | `brew install helm` |
| clickhouse-client | any | `brew install clickhouse` (optional, for local queries) |

Verify all tools:
```bash
docker info
kind version
kubectl version --client
helm version
```

---

## Quick start

```bash
# Clone / cd into the repo root
cd /path/to/clickhouse-multi-dc-federation

# Full setup: creates 3 clusters, deploys keepers, installs ClickHouse,
# patches federation config, applies schemas
bash setup.sh
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
bash scripts/verify.sh
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
kind create cluster --config manifests/fra/kind.yaml   # clickhouse-multi-dc-federation-demo-fra
kind create cluster --config manifests/muc/kind.yaml   # clickhouse-multi-dc-federation-demo-muc
kind create cluster --config manifests/ham/kind.yaml   # clickhouse-multi-dc-federation-demo-ham
```

Each cluster is a single-node (control-plane only, taint removed via
`nodeRegistration.taints: []`) with NodePort mappings for host access.
Skip if a cluster already exists.

### 3. Namespaces
Creates namespace `fra`, `muc`, or `ham` inside each respective cluster.

### 4. Deploy KeeperCluster + ClickHouseCluster CRs
Applies `manifests/{dc}/01-clickhouse-crs.yaml` to each cluster. The operator
reconciles the CRs and creates:

- A **KeeperCluster** (`{dc}-keeper`): single-node Keeper pod
  (`{dc}-keeper-0-0`) with headless service `{dc}-keeper-headless`.
- A **ClickHouseCluster** (`{dc}`): single shard, single replica CH pod
  (`{dc}-clickhouse-0-0-0`) with headless service `{dc}-clickhouse-headless`.

Then applies `manifests/{dc}/02-nodeport.yaml` to expose each DC's HTTP, TCP,
and TLS ports on the kind node.

Waits for all Keeper and CH pods to become Ready.

### 5. Patch federated_dcs (`patch-federation.sh`)
Discovers the InternalIP of each cluster's kind node and patches the
`ClickHouseCluster` CR on each DC with a `federated_dcs` remote_servers block
using those IPs and NodePorts:

```
FRA node IP: 172.18.0.2  → shard 0 in federated_dcs (localhost:9001 for FRA, NodePort for others)
MUC node IP: 172.18.0.3  → shard 1 in federated_dcs (localhost:9001 for MUC, NodePort for others)
HAM node IP: 172.18.0.4  → shard 2 in federated_dcs (localhost:9001 for HAM, NodePort for others)
```

Each DC uses `localhost:9001` for its own shard so ClickHouse marks it
`is_local=1` and reads locally instead of going through a network hop.
Followed by `SYSTEM RELOAD CONFIG` on each CH pod.

**Why NodePort IPs work across clusters:** all kind nodes share the Docker/
Podman `kind` network. A pod in cluster FRA that connects to
`MUC_NODE_IP:30902` has its traffic masqueraded through the FRA node (via
kindnet NAT), which then reaches the MUC node on the shared kind network.
kube-proxy on the MUC node forwards the NodePort to the MUC CH pod.

### 8. TLS setup (`setup-tls.sh`)
Runs `scripts/setup-tls.sh` which generates certs, creates K8s Secrets,
adds the `tcp-secure` NodePorts, patches all three `ClickHouseCluster` CRs,
and restarts pods if needed. See
[Design notes → TLS](#tls-for-cross-dc-communication) for details.

### 9. Schema deployment
Runs `scripts/apply-schemas.sh` with `--context kind-clickhouse-multi-dc-federation-demo-{dc}` for each DC:

```
Tier 1 (per DC): 01_tier1_local/{dc}_test_local.sql
Tier 2 (per DC): 02_tier2_regional/{dc}_dist_test_regional.sql
Tier 3 (per DC): 03_tier3_global/{dc}_dist_test_global.sql   ← needs Tier 1 in all DCs first
RBAC  (per DC):  04_rbac/roles_and_grants.sql
```

---

## Verifying pod naming

The operator derives names from the CR name (`fra`, `muc`, `ham`):

| Object | Expected name (FRA example) |
|--------|------------------------------|
| CH StatefulSet | `fra-clickhouse-0-0` |
| CH Pod | `fra-clickhouse-0-0-0` |
| CH headless service | `fra-clickhouse-headless` |
| CH Pod FQDN (in-cluster) | `fra-clickhouse-0-0-0.fra-clickhouse-headless.fra.svc.cluster.local` |
| Keeper Pod | `fra-keeper-0-0` |
| Keeper headless service | `fra-keeper-headless` |

Check actual names after setup:
```bash
kubectl get pods,svc --context kind-clickhouse-multi-dc-federation-demo-fra -n fra
kubectl get pods,svc --context kind-clickhouse-multi-dc-federation-demo-muc -n muc
kubectl get pods,svc --context kind-clickhouse-multi-dc-federation-demo-ham -n ham
```

---

## Running queries

### Via clickhouse-client on the host (plain TCP)

```bash
clickhouse client --host localhost --port 9801   # FRA
clickhouse client --host localhost --port 9802   # MUC
clickhouse client --host localhost --port 9803   # HAM
```

### Via clickhouse-client on the host (TLS)

```bash
# One-time: create a client config that trusts the demo CA
cat > /tmp/ch-tls-client.xml <<'EOF'
<config>
    <openSSL>
        <client>
            <caConfig>/tmp/clickhouse-tls/ca.crt</caConfig>
            <verificationMode>relaxed</verificationMode>
        </client>
    </openSSL>
</config>
EOF

clickhouse client --host localhost --port 9841 --secure --config-file /tmp/ch-tls-client.xml   # FRA
clickhouse client --host localhost --port 9842 --secure --config-file /tmp/ch-tls-client.xml   # MUC
clickhouse client --host localhost --port 9843 --secure --config-file /tmp/ch-tls-client.xml   # HAM
```

> `clickhouse client` has no `--ssl-ca-cert-file` flag; the CA must be passed
> via `--config-file`. `--accept-invalid-certificate` skips validation entirely
> and is only appropriate for quick smoke tests.

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
  -n fra fra-clickhouse-0-0-0 -- clickhouse-client --query "SELECT 1"
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
bash teardown.sh
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
> This is already applied in the demo — all three DCs have the setting active.

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

**TLS for cross-DC communication**
`scripts/setup-tls.sh` adds mutual TLS to all CH-to-CH federation traffic.
It is called automatically by `setup.sh` (step 8) and can also be run standalone
to retrofit TLS onto a running demo.

What it does:

1. Generates a self-signed CA (`/tmp/clickhouse-tls/ca.{key,crt}`).
2. Generates a per-DC server certificate with SANs covering the pod FQDN,
   headless-service FQDN, `localhost`, and the kind node IP.
3. Stores certs as K8s Secrets (`clickhouse-tls`) in each DC namespace.
4. Applies updated NodePort services that expose `tcp_port_secure: 9440` as
   NodePort 30941/30942/30943 (host ports 9841/9842/9843).
5. Patches each `ClickHouseCluster` CR to mount the secret and add:
   - `tcp_port_secure: 9440` in `extraConfig`
   - `openSSL.server` and `openSSL.client` blocks pointing at the mounted certs
   - `remote_servers.federated_dcs` with `secure: 1` — local shard via
     `localhost:9440`, remote shards via `<nodeIP>:3094{1,2,3}`
6. Handles stale Keeper state after pod restart (see "Stale Keeper digest" note
   below) and reapplies schemas.

Connect over TLS from the host:

```bash
# Create a client config that trusts the demo CA (one-time)
cat > /tmp/ch-tls-client.xml <<'EOF'
<config>
    <openSSL>
        <client>
            <caConfig>/tmp/clickhouse-tls/ca.crt</caConfig>
            <verificationMode>relaxed</verificationMode>
        </client>
    </openSSL>
</config>
EOF

clickhouse client --host 127.0.0.1 --port 9841 --secure --config-file /tmp/ch-tls-client.xml   # FRA
clickhouse client --host 127.0.0.1 --port 9842 --secure --config-file /tmp/ch-tls-client.xml   # MUC
clickhouse client --host 127.0.0.1 --port 9843 --secure --config-file /tmp/ch-tls-client.xml   # HAM
```

> **Note:** `clickhouse client` has no `--ssl-ca-cert-file` flag. The CA must
> be supplied via `--config-file` with an `<openSSL><client><caConfig>` block.
> `--accept-invalid-certificate` skips validation entirely and is only for
> quick smoke tests.

`verificationMode: relaxed` is used — the client verifies the server cert
against the CA but does not require a client cert. This is appropriate for
an internal demo; production deployments should use `verificationMode: strict`
with mutual TLS.

> **Note:** `clickhouse client` has no `--ssl-ca-cert-file` flag. The CA must
> be provided via `--config-file` with an `<openSSL><client><caConfig>` block,
> or by adding the CA to the system trust store. Using `--accept-invalid-certificate`
> bypasses validation entirely and is only appropriate for smoke tests.

**Stale Keeper digest after pod restart**
The ClickHouse operator restarts CH pods whenever the `ClickHouseCluster` CR
changes. Because both CH and Keeper use `emptyDir` storage (no PVCs in this
demo), a restarted CH pod presents a fresh replica UUID to Keeper. But if only
the CH pod restarts (Keeper keeps running), Keeper still holds the digest from
the previous CH instance. The operator's `DatabaseSync` then fails with
`code: 253` ("Replica node already exists and contains unexpected value:
digest"). Fix: restart both Keeper and CH pods together — `setup-tls.sh`
handles this automatically after the TLS patch.
