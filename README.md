# Lukewarm

A cost-effective framework for declarative SQL models over Apache Iceberg — without the expense of constant re-materialization.

---

## The Problem

Modern data lake and warehouse platforms (Snowflake, Databricks, and open-source equivalents) offer powerful tools for writing declarative SQL models that materialize into denormalized datasets — Snowflake Dynamic Tables, Databricks Live Tables, and similar. However, keeping these datasets continuously or frequently refreshed gets expensive fast.

The underlying data doesn't change that quickly. Most of the time, you're paying to recompute results that are largely the same as the last run.

## The Idea

Lukewarm introduces a **hot/cold read pattern** for materialized Iceberg models:

- **Cold data** — the last fully materialized snapshot (cheap to read, pre-computed, stored in Iceberg)
- **Hot data** — changes that have arrived since the last materialization (a delta, not yet merged)
- **Lukewarm query** — a declarative SQL model that, at read time, automatically merges cold + hot to give a fresh result without requiring a full re-materialization

```
Cold data  (last materialized Iceberg snapshot)
    +
Hot data   (Iceberg changes since last snapshot)
    =
Lukewarm   (fresh result, no full recompute)
```

The name says it all — not cold (stale), not hot (expensive), just lukewarm.

---

## How It Works

1. **You define models** as declarative `.sql` files (dbt-style), with dependencies expressed via `ref()`.
2. **A scheduler** runs on a cron cadence (e.g. every 2 hours). Before materializing, it checks whether the source Iceberg tables have produced a new snapshot since the last run. If not, it skips — zero compute wasted.
3. **When a model runs**, the framework rewrites the query to read from the last cold snapshot plus any hot delta changes, then writes the result back to Iceberg.
4. **At query time**, users run their declared SQL model. Lukewarm rewrites it under the hood to merge cold + hot, giving a fresh view without full recomputation.

---

## Architecture

```
APIs / External Sources
        │
        ▼
  Kafka (or any streaming tool)
        │
        ▼  Spark Structured Streaming
  Iceberg Tables  ──────────────────── raw normalized data
        │
        ▼
  Lukewarm Framework
  ├── Model Parser      — reads .sql files, builds dependency DAG
  ├── Scheduler         — cron + Iceberg snapshot change detection
  ├── Query Rewriter    — merges cold snapshot + hot delta at read time
  ├── Materializer      — executes via Trino, writes back to Iceberg
  └── Metadata Store    — tracks snapshot IDs and materialization state (SQLite)
        │
        ▼
  Trino  (query engine)
        │
        ▼
  Consumers / BI Tools
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Table format | Apache Iceberg |
| Query engine | Trino |
| Stream ingestion | Apache Kafka |
| Stream processing | Spark Structured Streaming |
| Object storage | S3 / GCS / ADLS / MinIO |
| Iceberg catalog | Hive Metastore (production), REST catalog (local dev) |
| Framework language | Python |
| Metadata store | SQLite (local dev), upgradeable to PostgreSQL |
| Kubernetes platform | Stackable Data Platform |

> Lukewarm is designed to be technology-agnostic at its catalog and query engine boundaries.
> Any Trino-compatible deployment and any Hive Metastore-compatible catalog will work.
> Future versions aim to support additional query engines and catalog implementations.

---

## Project Structure

```
lukewarm/
├── lukewarm/                  # core Python package (coming soon)
│   ├── models/                # SQL parsing, DAG construction
│   ├── rewriter/              # hot + cold query rewriting
│   ├── scheduler/             # cron + Iceberg snapshot change detection
│   ├── materializer/          # Trino execution, Iceberg writes
│   └── metadata/              # SQLite snapshot tracking store
├── models/                    # user-defined declarative .sql model files
├── infra/
│   ├── docker-compose.yml     # local development stack
│   ├── config/
│   │   ├── hive/              # Hive Metastore configuration
│   │   └── trino/catalog/     # Trino Iceberg catalog configuration
│   ├── helm/
│   │   ├── charts/            # vendored Helm charts (MinIO, PostgreSQL)
│   │   ├── values/            # Helm values for each chart
│   │   └── stackable/         # Stackable CRD manifests (ZooKeeper, Kafka, Hive, Trino, Spark)
│   └── local_infra_setup.md   # local dev infrastructure guide
├── tests/
├── status.md                  # current project status and next steps
└── README.md
```

---

## Local Development

### Prerequisites
- Docker and Docker Compose

### Start the stack

```bash
cd infra
docker compose up -d
```

This starts:
- **MinIO** — object storage (http://localhost:9001, `minioadmin/minioadmin`)
- **Iceberg REST Catalog** — catalog server (http://localhost:8181)
- **Trino** — query engine (http://localhost:8080)
- **Kafka** — streaming (localhost:9092)

### Verify

```bash
# All services healthy
docker compose ps

# Trino can see the Iceberg catalog
docker exec lukewarm-trino trino --execute "SHOW CATALOGS"

# Query the demo star schema
docker exec lukewarm-trino trino --execute "
  SELECT t.transaction_id, t.trans_date, t.sale_price, s.city, c.category
  FROM iceberg.demo.sales_transactions t
  JOIN iceberg.demo.stores  s ON t.store_id = s.id
  JOIN iceberg.demo.catalog c ON t.item_id  = c.id
  ORDER BY t.trans_date;
"
```

See [`infra/local_infra_setup.md`](infra/local_infra_setup.md) for full details.

---

## Production Deployment (Kubernetes / Stackable)

Helm charts and Stackable CRD manifests are vendored in `infra/helm/`.

```bash
# Install Stackable operators
stackablectl operator install commons secret listener zookeeper kafka hive trino spark-k8s

# Deploy MinIO and PostgreSQL
helm install minio infra/helm/charts/minio -f infra/helm/values/minio-values.yaml
helm install postgresql infra/helm/charts/postgresql -f infra/helm/values/postgresql-values.yaml

# Deploy data platform services
kubectl apply -f infra/helm/stackable/
```

---

## Status

See [`status.md`](status.md) for current development status and next steps.

---

## License

TBD
