# Local Infrastructure Setup

This Docker Compose stack provides a local development environment for the Lukewarm framework.
It is **not** a reference deployment — it is purely a convenience for local development and testing.

> In production, customers bring their own Iceberg, Trino, and streaming infrastructure.
> Lukewarm is designed to sit on top of any compatible implementation of these technologies.

---

## Stack Overview

```
APIs / Data Sources
      │
      ▼
   Kafka (or any streaming tool)
      │
      ▼  (stream processing, e.g. Spark Structured Streaming)
 Iceberg Tables  ◄─── cold data (last materialized snapshot)
      │               hot data  (changes since last snapshot)
      ▼
  Lukewarm Framework  (hot + cold query rewriting)
      │
      ▼
   Trino  (query execution)
```

---

## Services

### MinIO
- **Image:** `minio/minio:latest`
- **Role:** S3-compatible object storage. Stores all Iceberg table data files and metadata.
- **Ports:** `9000` (S3 API), `9001` (web console)
- **Credentials:** `minioadmin / minioadmin`
- **Bucket:** `lukewarm` (auto-created on startup via `minio-init`)
- **Console:** http://localhost:9001

### Iceberg REST Catalog
- **Image:** `tabulario/iceberg-rest:latest`
- **Role:** Lightweight Iceberg catalog server. Manages table metadata over a standard REST API.
- **Port:** `8181`
- **Notes:**
  - Used for local dev only. Backed by an in-memory SQLite database — catalog state is lost on container restart.
  - In production, Hive Metastore is preferred (see [Catalog: Local Dev vs Production](#catalog-local-dev-vs-production) below).
  - Warehouse location: `s3://lukewarm/warehouse` backed by MinIO.

### Trino
- **Image:** `trinodb/trino:442`
- **Role:** SQL query engine. Executes Lukewarm's hot+cold rewritten queries against Iceberg tables.
- **Port:** `8080`
- **Catalog:** `iceberg` — configured in `config/trino/catalog/iceberg.properties` to point at the Iceberg REST catalog and MinIO.
- **UI:** http://localhost:8080

### Kafka
- **Image:** `apache/kafka:3.7.1`
- **Role:** Streams raw data from external APIs into the platform. Runs in KRaft mode (no ZooKeeper required).
- **Port:** `9092`
- **Notes:** Used here as the streaming layer for local development. In production, any streaming tool
  (Kafka, Kinesis, Pulsar, etc.) can serve this role. Lukewarm itself does not depend on Kafka directly.

### Spark Structured Streaming _(Kubernetes / Stackable only — not in Docker Compose)_
- **Operator:** `spark-k8s` (Stackable)
- **Role:** Consumes raw events from Kafka topics and writes them to Iceberg tables. This is the ingestion
  layer that populates the cold storage tier that Lukewarm reads from.
- **Manifest:** `helm/stackable/spark.yaml`
- **Notes:** Spark is resource-intensive and not included in the local Docker Compose stack. For local
  development, Iceberg tables can be seeded directly via Trino. In production, the `SparkApplication`
  manifest defines a Spark Structured Streaming job that runs on Kubernetes via the Stackable `spark-k8s` operator.

---

## Catalog: Local Dev vs Production

The local stack uses the **Iceberg REST catalog** for simplicity. Production deployments should use
**Hive Metastore (HMS)**.

### Why Hive Metastore is preferred for production

| Concern | Hive Metastore | Iceberg REST (tabulario) |
|---|---|---|
| **Persistence** | Durable — metadata in PostgreSQL | In-memory SQLite by default, lost on restart |
| **Ecosystem support** | Broadest — Spark, Trino, Flink, Hive all support it natively | Newer — not all engines support REST yet |
| **Partition statistics** | Rich stats used by Spark for query planning and optimization | Limited stats |
| **Access control** | Integrates with Apache Ranger, AWS Lake Formation, etc. | Minimal built-in auth |
| **Scale** | Battle-tested at petabyte scale with millions of partitions | Suitable for smaller workloads |
| **Stackable support** | Native Stackable `hive` operator | No Stackable operator |

The REST catalog spec is becoming the new open standard (AWS Glue, Polaris, Nessie, Unity Catalog all
implement it), and Trino supports it well. But for a production deployment on Stackable with Spark
Structured Streaming, HMS backed by PostgreSQL is the right choice today.

The Stackable production manifests in `helm/stackable/` use Hive Metastore accordingly.

---

## Configuration Files

| File | Purpose |
|---|---|
| `config/hive/hive-site.xml` | Reserved for Hive Metastore overrides (production) |
| `config/trino/catalog/iceberg.properties` | Trino Iceberg catalog — REST catalog URI and MinIO S3 credentials |

---

## Starting and Stopping

```bash
# Start the stack
docker compose up -d

# Stop the stack (preserves volumes)
docker compose down

# Stop and remove all data volumes (full reset)
docker compose down -v
```

## Verifying the Stack

```bash
# Check all services are healthy
docker compose ps

# Verify Trino can see the Iceberg catalog
docker exec lukewarm-trino trino --execute "SHOW CATALOGS"

# Query the demo star schema
docker exec lukewarm-trino trino --execute "
  SELECT
    t.transaction_id,
    t.trans_date,
    t.sale_price,
    s.city,
    s.region,
    c.category,
    c.vendor
  FROM iceberg.demo.sales_transactions t
  JOIN iceberg.demo.stores  s ON t.store_id = s.id
  JOIN iceberg.demo.catalog c ON t.item_id  = c.id
  ORDER BY t.trans_date;
"
```

---

## Demo Schema

A star schema is pre-loaded in `iceberg.demo` for development and testing:

```
iceberg.demo
  ├── sales_transactions  (fact)       — transaction_id, sale_price, item_id, trans_date, store_id
  ├── stores              (dimension)  — id, manager, city, state, zip, region
  └── catalog             (dimension)  — id, cost, vendor, category
```

`sales_transactions` is partitioned by `month(trans_date)`.

---

## Production Orientation

Lukewarm is designed to be technology-agnostic at its boundaries:

| Layer | Local Dev | Production (customer-owned) |
|---|---|---|
| Object Storage | MinIO | S3, GCS, ADLS, or any S3-compatible store |
| Iceberg Catalog | REST catalog (tabulario) | Hive Metastore (recommended), Glue, Nessie, etc. |
| Query Engine | Trino | Any Trino-compatible deployment (Stackable, Starburst, etc.) |
| Stream Ingestion | Kafka | Kafka, Kinesis, Pulsar, or any streaming tool |
| Stream Processing | _(seed via Trino)_ | Spark Structured Streaming (or Flink, etc.) |

The local Docker Compose stack exists only to make it easy to develop and test the framework
without needing access to a full cloud or Kubernetes environment.
