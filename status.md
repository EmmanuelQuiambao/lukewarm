# Lukewarm — Project Status

_Last updated: 2026-03-01_

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

**Demo data (`iceberg.demo`):**
- `sales_transactions` — fact table, 8 rows, partitioned by `month(trans_date)`
- `stores` — dimension table, 5 rows
- `catalog` — dimension table, 5 rows

**Production infra (Kubernetes / Stackable):**
- Helm charts vendored: MinIO (`bitnami`), PostgreSQL (`bitnami`)
- Stackable CRD manifests written: ZooKeeper, Kafka, Hive Metastore, Trino, Spark
- Not yet deployed (requires a real Kubernetes cluster with sufficient CPU)

### Framework — Not Started 🔴

The core Python package (`lukewarm/`) has not been written yet.
The project structure is defined but empty.

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
- [ ] Initialize the Python project (`pyproject.toml`, package structure)
- [ ] Set up git repo and push initial commit
- [ ] Decide on Terraform for infrastructure-as-code (MinIO bucket setup, Iceberg schema init)

### Framework — Core
- [ ] Model parser — read `.sql` files, extract `ref()` dependencies, build DAG
- [ ] DAG resolver — topological sort for materialization order
- [ ] Iceberg snapshot tracker — compare current vs last-seen snapshot ID per model
- [ ] Scheduler — cron runner with skip-if-unchanged logic
- [ ] Query rewriter — merge cold snapshot + hot delta into rewritten SQL
- [ ] Materializer — execute rewritten query via Trino, write result back to Iceberg
- [ ] Metadata store — SQLite schema for snapshot IDs and materialization history

### Infrastructure
- [ ] Terraform setup for local dev (MinIO bucket, Iceberg schemas)
- [ ] Test Stackable deployment on a real Kubernetes cluster when available

### Future / Backlog
- [ ] Support for multiple Hive Metastore-compatible catalogs
- [ ] Support for non-Trino query engines
- [ ] Model versioning / lineage tracking
- [ ] Web UI or CLI for inspecting model state and materialization history
- [ ] dbt compatibility layer (parse existing dbt models)

---

## Open Questions

- Should Terraform manage Iceberg schema/table creation, or should that be handled by the framework itself on first run?
- What is the right abstraction for catalog connectivity — thin wrapper over the Thrift API, or a higher-level catalog interface?
- Should the scheduler be embedded in the framework CLI or run as a standalone service?
