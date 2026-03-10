# Lukewarm — Project Status

_Last updated: 2026-03-10_

---

## What Is This File

A working document for getting back up to speed quickly. Covers what's been built, key decisions made, known issues, and what comes next.

---

## Current State

### Infrastructure — Done ✅

The local development environment is fully working.

**Local stack (`infra/docker-compose.yml`):**
| Service | Image | Port | Status |
|---|---|---|---|
| MinIO | `minio/minio:latest` | 9000 / 9001 | Working |
| Iceberg REST Catalog | `tabulario/iceberg-rest:latest` | 8181 | Working |
| Trino | `trinodb/trino:442` | 8080 | Working |
| Kafka | `apache/kafka:3.7.1` | 9092 | Working |
| Kafka UI | `provectuslabs/kafka-ui:latest` | 8090 | Working |
| Spark master | `apache/spark:3.5.1` | 8082 / 7077 | Working |
| Spark worker | `apache/spark:3.5.1` | — | Working |
| Airflow webserver | `apache/airflow:2.10.0` | 8081 | Working |
| Airflow scheduler | `apache/airflow:2.10.0` | — | Working |

**Demo data (`iceberg.demo`):**
- `sales_transactions` — fact table, 8 rows, partitioned by `month(trans_date)`
- `stores` — dimension table, 5 rows
- `catalog` — dimension table, 5 rows

**Crypto pipeline (`iceberg.crypto`):**
- `ticker` — append-only Binance ticker events, partitioned by `day(event_time)`. Confirmed working end-to-end.

**Production infra (Kubernetes / Stackable):**
- Helm charts vendored: MinIO (`bitnami`), PostgreSQL (`bitnami`)
- Stackable CRD manifests written: ZooKeeper, Kafka, Hive Metastore, Trino, Spark
- Not yet deployed (requires a real Kubernetes cluster with sufficient CPU)

### Crypto Streaming Pipeline — Done ✅

End-to-end pipeline confirmed working:

```
Binance WebSocket (!ticker@arr)
    → producers/binance_ticker.py   [Python, runs on host]
    → Kafka topic: crypto.ticker
    → jobs/ticker_to_iceberg.py     [Spark Structured Streaming]
    → iceberg.crypto.ticker         [Parquet, partitioned by day]
    → Trino                         [queryable]
```

Use `scripts/start_pipeline.sh` to bring everything up.

**Known limitations:**
- Producer has no crash-recovery for missed ticks (WebSocket is push-only, no replay). A process supervisor (systemd/K8s Deployment) is needed for production. Transient WebSocket drops are handled with auto-reconnect.
- Spark job has no `.trigger(processingTime=...)` set — runs as fast as possible, producing many small Iceberg snapshots. Should add a trigger interval (60–300s) before production use.
- Spark job runs via a shell script inside the container (`/tmp/submit.sh`), not yet wired into Airflow.

### Framework — Not Started 🔴

The core Python package (`lukewarm/`) has not been written yet.
The project structure is defined but all module `__init__.py` files are stubs only.

### Architecture Research — Done ✅

Two research documents written. Design decisions made for the framework core:

- `architecture_research.md` — Iceberg metadata model, join handling design (4 scenarios), DLT/Snowflake internals, competitive landscape, build implications
- `infrastructure_considerations.md` — Kafka scaling, Spark tuning, Flink vs Spark, Iceberg vs Hudi vs Delta Lake, recommended production stack

**Key findings:**
- No existing system combines a declarative SQL model DAG with read-time hot/cold snapshot merging over Iceberg. Lukewarm occupies this space alone.
- Snowflake Dynamic Tables and DLT both hit real limitations on joins (DLT: 2–5 join max for incremental; Snowflake: efficiency cliff above 5% change rate) and dimension change handling (DLT streaming tables serve stale dimension data silently). Lukewarm is designed to handle both correctly.
- Apache Fluss + Iceberg (Alibaba/Ververica, 2025) is the closest architectural analog — hot tier + cold tier + union read — but operates at the raw ingestion layer (not derived models) and is Flink-only.
- AWS Glue shipped native Iceberg materialized views in November 2025. Lukewarm should align metadata vocabulary with Iceberg's MV spec (`fresh`, `stale`, `invalid`) for interoperability.

---

## Key Decisions Made

### Architecture
- **Hot/cold pattern**: cold = last Iceberg snapshot, hot = delta since last snapshot. Lukewarm merges both at query time.
- **Model definition**: dbt-style `.sql` files with `ref()` for dependencies
- **Scheduler**: cron-based, skips materialization if source Iceberg snapshot IDs haven't changed since last run
- **Metadata store**: SQLite to start (tracks snapshot IDs and materialization history per model)
- **Language**: Python

### Infrastructure
- **Iceberg catalog (local dev)**: Iceberg REST catalog (`tabulario/iceberg-rest`) — simpler, no Postgres dependency, ARM64 compatible
- **Iceberg catalog (production)**: Hive Metastore backed by PostgreSQL — durable, richer Spark stats, Stackable native support, battle-tested
- **Query engine**: Trino — customer-owned, Lukewarm submits queries via JDBC/HTTP
- **Stream ingestion**: Kafka for local dev — but Lukewarm is not coupled to Kafka; any streaming tool works
- **Kubernetes platform**: Stackable Data Platform
- **Local K8s**: Abandoned (only 2 CPUs on dev machine — insufficient for Stackable operators)

### Catalog Note
- We attempted `apache/hive:4.0.0` for local dev but hit a persistent S3 path creation issue (S3AFileSystem classpath problems in Hive 4.0.0 + MinIO). Switched to `tabulario/iceberg-rest` which is ARM64-compatible and works cleanly.
- Production Stackable manifests still use Hive Metastore — that decision stands.

### Spark Package Note
- Use `org.apache.iceberg:iceberg-aws-bundle:1.5.2` (NOT `software.amazon.awssdk:bundle`) — the raw SDK conflicts with classes shaded inside `iceberg-spark-runtime`.
- Must pass `AWS_REGION=us-east-1` to executors via `spark.executorEnv.AWS_REGION` and `-Daws.region=us-east-1` JVM opt. The SDK v2 `DefaultAwsRegionProviderChain` on executors can't find the region from Spark catalog config alone.

### Project Orientation
- Lukewarm sits **on top of** customer-owned Iceberg + Trino. Customers bring their own implementation.
- Framework should be **catalog-agnostic** long term — designed to connect to any Hive Metastore-compatible catalog, with extensibility to other catalog types.
- Kafka and Spark are infrastructure concerns, not Lukewarm concerns. Lukewarm reads Iceberg tables; it doesn't care how data got there.

---

## Environment

| Tool | Version | Location |
|---|---|---|
| Docker | 29.2.1 | `/usr/bin/docker` |
| kind | 0.27.0 | `~/.local/bin/kind` |
| kubectl | v1.35.2 | `~/.local/bin/kubectl` |
| helm | v3.20.0 | `~/.local/bin/helm` |
| stackablectl | 1.2.2 | `~/.local/bin/stackablectl` |
| Python | 3.13 (Homebrew) | `/home/linuxbrew/.linuxbrew/opt/python@3.13/bin` |
| Git | 2.43.0 | `/usr/bin/git` |
| Architecture | ARM64 (aarch64) | — |

**GitHub:** `git@github.com:EmmanuelQuiambao/lukewarm.git`

**Project path:** `~/projects/lukewarm/`

---

## Next Steps

### Immediate
- [ ] Add `.trigger(processingTime="60 seconds")` to the Spark streaming job
- [ ] Wire Spark job submission into an Airflow DAG (replace manual `/tmp/submit.sh`)
- [ ] Add process supervisor or Airflow DAG to keep the Binance producer alive

### Framework — Core

Build order informed by architecture research. Each step unblocks the next.

- [ ] **1. Model declaration parser** — read `.sql` files + `.yml` sidecar, extract `ref()` dependencies, validate fact/dim/key declarations
- [ ] **2. DAG resolver** — topological sort, `DOWNSTREAM` lag propagation (skip if no downstream needs it)
- [ ] **3. Snapshot tracker** — query `$snapshots` metadata table via Trino or PyIceberg, compare to SQLite, compute source change rate
- [ ] **4. Strategy classifier** — select rewrite strategy based on query shape and snapshot state:
  - `APPEND_ONLY` — source is append-only, no joins
  - `DIMENSION_JOIN` — fact × dimension join with new fact rows
  - `DIMENSION_CHANGE` — dimension update affecting old cold fact rows (LEFT or INNER)
  - `GROUP_AGGREGATE` — recompute only affected grouping keys
  - `FORCE_FULL` — change rate exceeds threshold or unsupported SQL construct
- [ ] **5. Query rewriter** — generate cold CTE (`FOR VERSION AS OF`) + hot CTE (incremental files) + merge logic per strategy; handle INNER JOIN exclusion case
- [ ] **6. Hot-delta threshold / circuit breaker** — if source change rate exceeds threshold, force `FORCE_FULL` strategy instead of incremental merge
- [ ] **7. Materializer** — execute rewritten SQL via Trino, write result back to Iceberg
- [ ] **8. Metadata store** — SQLite schema tracking per materialization run:
  - `source_snapshot_id`, `result_snapshot_id`, `materialized_at`
  - `strategy_used`, `refresh_mode` (incremental | full)
  - `rows_added`, `rows_updated`, `rows_excluded` (INNER JOIN invalidations)
  - `source_change_pct`, `duration_ms`

### Infrastructure
- [ ] Test Stackable deployment on a real Kubernetes cluster when available

### Future / Backlog
- [ ] Support for multiple Hive Metastore-compatible catalogs
- [ ] Support for non-Trino query engines (DuckDB, Athena)
- [ ] Model versioning / lineage tracking
- [ ] Web UI or CLI for inspecting model state and materialization history
- [ ] dbt compatibility layer (parse existing dbt models)
- [ ] Aggregation support — `GROUP_AGGREGATE` strategy for recomputing only affected grouping keys
- [ ] Multi-level model hot propagation — fold deep DAG into single rewritten SQL
- [ ] Align metadata store with Iceberg MV spec (`fresh` / `stale` / `invalid`) for interoperability with Iceberg-compatible tools
- [ ] Join count threshold — configurable per model, force `FORCE_FULL` when exceeded (DLT defaults to 2, max 5)

### Kafka — Production Considerations (revisit later)
- [ ] Choose a managed Kafka provider for production deployment
- Traffic from `!ticker@arr` is consistent (~1 push/second from Binance, each containing all symbols). Volume per tick floats with market activity (more symbols cross the volume threshold during high volatility). Not random — predictable floor/ceiling based on actively traded pairs.
- Partitions are the unit of parallelism — Spark reads one partition per task, so partition count caps consumer concurrency. Can increase partitions but never decrease; worth slight over-provisioning upfront.
- **Managed options to evaluate:**
  | Option | Notes |
  |---|---|
  | Confluent Cloud | Richest ecosystem (Schema Registry, ksqlDB, connectors). Expensive at scale. |
  | AWS MSK | Natural fit if AWS-native. Broker scaling is manual; less elastic than Confluent. |
  | AWS MSK Serverless | Good for spiky/unpredictable traffic. Higher per-GB cost, some API limits. |
  | Redpanda Cloud | Kafka-compatible, lower latency, no JVM. Smaller connector ecosystem. |
  | Aiven | Multi-cloud flexibility (GCP/Azure/DO). Less full-featured than Confluent. |
  | Stackable (self-managed) | Keeps everything in-cluster. You own the ops burden. |
- MSK is the natural default if the customer is AWS-native (pairs well with S3 + Glue). Confluent is the enterprise default when teams need connectors and Schema Registry.
- Note: Kafka retention (default 7 days) means the Spark job can replay from any offset within that window. The producer's lack of replay is a WebSocket limitation, not a Kafka limitation.

---

## Open Questions

- Should Terraform manage Iceberg schema/table creation, or should that be handled by the framework itself on first run?
- What is the right abstraction for catalog connectivity — thin wrapper over the Thrift API, or a higher-level catalog interface?
- Should the scheduler be embedded in the framework CLI or run as a standalone service?
- For multi-level models (model A → model B → model C), should hot data be propagated via query folding (one SQL) or eager propagation (materialize intermediate hot deltas as temp tables)? Query folding is more elegant; eager propagation is simpler for deep DAGs.
- Should the `.yml` sidecar be required for all models or only models with joins? Simple filter/projection models could be inferred automatically from SQL parsing alone.
