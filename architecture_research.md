# Lukewarm — Architecture Research

_Last updated: 2026-03-10_

Research and design decisions covering Iceberg metadata, join handling, incremental view maintenance patterns from industry systems, and competitive landscape. Intended to inform the framework core build.

---

## Table of Contents

1. [Iceberg Metadata and Hot Data Detection](#1-iceberg-metadata-and-hot-data-detection)
2. [Join Handling Design](#2-join-handling-design)
3. [Industry Research: DLT and Snowflake Dynamic Tables](#3-industry-research-dlt-and-snowflake-dynamic-tables)
4. [Competitive Landscape](#4-competitive-landscape)
5. [Lukewarm's Differentiators](#5-lukewarms-differentiators)
6. [Build Implications](#6-build-implications)

---

## 1. Iceberg Metadata and Hot Data Detection

### Iceberg's Metadata Chain

Every write to an Iceberg table produces a new snapshot. The metadata chain:

```
metadata.json
    └── snapshot 1001  (T1 — initial load)
    └── snapshot 1002  (T2 — Spark micro-batch)
    └── snapshot 1003  (T3 — Spark micro-batch)
    └── snapshot 1004  (T4 — current)
            └── manifest list
                    └── manifest A  → data files added in snapshot 1001
                    └── manifest B  → data files added in snapshot 1002
                    └── manifest C  → data files added in snapshot 1003
                    └── manifest D  → data files added in snapshot 1004
```

Each snapshot carries:
- `snapshot_id` — unique long integer
- `parent_snapshot_id` — chain back to origin
- `committed_at` — timestamp
- Summary: `added-files`, `added-records`, `operation`

### Iceberg Metadata Tables (queryable via Trino)

```sql
-- All snapshots
SELECT snapshot_id, parent_id, committed_at, operation
FROM "iceberg"."crypto"."ticker$snapshots"
ORDER BY committed_at DESC;

-- Data files and which snapshot added them
SELECT content, file_path, record_count, added_snapshot_id
FROM "iceberg"."crypto"."ticker$files";

-- Full snapshot history
SELECT * FROM "iceberg"."crypto"."ticker$history";

-- Manifest files
SELECT * FROM "iceberg"."crypto"."ticker$manifests";
```

### Two Approaches to Finding Hot Data

**Approach 1: Trino time travel (simpler, event_time proxy)**
```sql
-- Records added since snapshot 1001
SELECT * FROM iceberg.crypto.ticker
WHERE event_time > (
    SELECT committed_at FROM "iceberg"."crypto"."ticker$snapshots"
    WHERE snapshot_id = 1001
)
```
Slightly imprecise — relies on event timestamp, not Iceberg file metadata.

**Approach 2: PyIceberg incremental scan (precise, file-level)**
```python
from pyiceberg.catalog import load_catalog

catalog = load_catalog("rest", uri="http://localhost:8181")
table = catalog.load_table("crypto.ticker")

# Returns only Parquet files added after snapshot 1001
scan = table.incremental_append_scan(from_snapshot_id=1001)
arrow_table = scan.to_arrow()
```
This is file-level precision — Iceberg gives you exactly the list of Parquet files added since snapshot X, without reading anything older. No `event_time` heuristic.

### What the Metadata Store Tracks Per Model

```
model_name    source_snapshot_id    result_snapshot_id    materialized_at
top_movers    1001                  2001                  2026-03-09 10:00:00
```

- `source_snapshot_id` — snapshot of the source table when last materialized. Everything after this is hot.
- `result_snapshot_id` — snapshot of the materialized output. This is the cold layer read target.

### Query Rewriter Shape for ticker → top_movers

```sql
WITH cold AS (
    SELECT * FROM iceberg.demo.top_movers
    FOR VERSION AS OF <result_snapshot_id>
),
hot AS (
    SELECT
        symbol, last_price, price_change_pct, high_24h, low_24h,
        ROUND(high_24h - low_24h, 4)                               AS range_24h,
        ROUND((high_24h - low_24h) / NULLIF(low_24h, 0) * 100, 2) AS range_pct,
        ROUND(quote_volume_24h / 1e6, 2)                           AS volume_usdt_m,
        num_trades_24h, event_time
    FROM iceberg.crypto.ticker
    WHERE event_time > <source_snapshot_committed_at>
      AND ABS(price_change_pct) > 3.0
      AND quote_volume_24h > 10000000
),
-- Dedup hot: ticker is append-only, latest row per symbol wins
hot_deduped AS (
    SELECT * FROM hot
    WHERE ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY event_time DESC) = 1
),
merged AS (
    SELECT * FROM hot_deduped
    UNION ALL
    SELECT * FROM cold
    WHERE symbol NOT IN (SELECT symbol FROM hot_deduped)
)
SELECT * FROM merged
ORDER BY ABS(price_change_pct) DESC
LIMIT 50
```

**Key nuance:** because `ticker` is append-only with no deduplication, the hot CTE needs a `ROW_NUMBER()` dedup per symbol before merging. The rewriter must account for this per source table semantics.

---

## 2. Join Handling Design

### Model Declaration

Fact/dimension roles must be declared explicitly alongside the `.sql` file:

```yaml
# models/denorm_ticker.yml
model: denorm_ticker
fact:
  table: ticker
  key: [symbol, event_time]       # unique row identifier in the result
joins:
  - table: exchanges
    type: LEFT
    on: ticker.exchange_id = exchanges.id
    role: dimension
    dimension_key: id
  - table: symbols_meta
    type: INNER
    on: ticker.symbol = symbols_meta.symbol
    role: dimension
    dimension_key: symbol
```

`fact_key` is required — it is how the rewriter identifies which cold rows to override or exclude when delta data arrives.

### The Four Scenarios

Define:
```
F_cold = fact snapshot at last materialization
F_hot  = new fact files since last materialization
D_cold = dimension snapshot at last materialization
D_hot  = changed dimension files since last materialization
R_cold = last materialized result (frozen output)
```

---

#### Scenario 1 — New fact rows, dimension unchanged

Simplest case. Hot = new fact rows joined against current dimension.

```sql
WITH hot AS (
    SELECT f.*, d.exchange_name
    FROM <new fact files> f
    LEFT JOIN iceberg.ref.exchanges d ON f.exchange_id = d.id
),
cold AS (
    SELECT * FROM iceberg.demo.denorm_ticker
    FOR VERSION AS OF <result_snapshot>
    WHERE (symbol, event_time) NOT IN (SELECT symbol, event_time FROM hot)
)
SELECT * FROM hot UNION ALL SELECT * FROM cold
```

- **LEFT JOIN:** new fact rows always appear, dim cols NULL if no match
- **INNER JOIN:** new fact rows only appear if they match the dimension — correct semantics, no special handling needed

---

#### Scenario 2 — Dimension updates on new fact rows

New fact rows AND dimension changed. New fact rows always get current dimension values — they were never in cold. SQL shape is identical to Scenario 1. No special handling required.

---

#### Scenario 3 — Dimension updates on OLD fact rows (already in cold)

The critical scenario. Cold rows joined to changed dimension rows are now stale.

**Step 1:** identify changed dimension keys
```sql
WITH changed_dim_keys AS (
    SELECT id FROM <dimension incremental files>
)
```

**Step 2:** find affected cold result rows
```sql
affected_cold AS (
    SELECT r.*
    FROM iceberg.demo.denorm_ticker FOR VERSION AS OF <result_snapshot> r
    WHERE r.exchange_id IN (SELECT id FROM changed_dim_keys)
)
```

**Step 3 — LEFT JOIN:** re-join affected cold fact rows against current dimension
```sql
hot_from_dim_change AS (
    SELECT f.symbol, f.event_time, f.last_price, d.exchange_name
    FROM iceberg.crypto.ticker FOR VERSION AS OF <fact_cold_snapshot> f
    LEFT JOIN iceberg.ref.exchanges d ON f.exchange_id = d.id
    WHERE f.exchange_id IN (SELECT id FROM changed_dim_keys)
)
-- Affected cold rows are always replaced with updated dimension values
```

**Step 3 — INNER JOIN (exclusion case):** dimension change can shrink the result
```sql
hot_from_dim_change AS (
    -- Only fact rows that STILL satisfy the inner join condition
    SELECT f.symbol, f.event_time, f.last_price, d.exchange_name
    FROM iceberg.crypto.ticker FOR VERSION AS OF <fact_cold_snapshot> f
    INNER JOIN iceberg.ref.exchanges d ON f.exchange_id = d.id
    WHERE f.exchange_id IN (SELECT id FROM changed_dim_keys)
    -- Rows where join no longer matches are absent here → excluded from result
)

cold AS (
    SELECT * FROM iceberg.demo.denorm_ticker FOR VERSION AS OF <result_snapshot>
    WHERE (symbol, event_time) NOT IN (
        SELECT symbol, event_time FROM affected_cold  -- remove all affected
    )
    -- hot_from_dim_change adds back only rows still satisfying the join
)
```

---

#### Scenario 4 — Both new fact rows AND dimension changes

Combination of Scenarios 1 and 3:

```
Hot_from_new_facts   = F_hot ⋈ D_current
Hot_from_dim_changes = F_cold[affected by D_hot] ⋈ D_current
Hot = Hot_from_new_facts ∪ Hot_from_dim_changes (dedup by fact key)
Cold = R_cold MINUS all rows whose fact keys appear in Hot
```

For INNER JOIN: also subtract cold rows invalidated by dimension changes.

---

### LEFT JOIN vs INNER JOIN Difference Summary

| Scenario | LEFT JOIN | INNER JOIN |
|---|---|---|
| New fact row, no dim match | Row appears, dim cols NULL | Row excluded |
| New fact row, dim matches | Row appears with dim values | Row appears with dim values |
| Dim update on old fact row | Row updated with new dim values | Row updated if still matches, excluded if not |
| Dim delete affecting old fact row | Row stays, dim cols go NULL | Row removed from result |

**The INNER JOIN exclusion case is the most operationally significant** — a dimension change can silently shrink a materialized result. The metadata store should track `rows_added`, `rows_updated`, `rows_excluded` per materialization for observability.

### Join Classification Strategy

| Join type | Strategy |
|---|---|
| Fact × stable dimension | Hot = new fact rows × current dimension |
| Fact × slowly changing dimension | Hot = new fact rows × current dim + re-join rows affected by dim changes |
| Fact × Fact | Force full recompute if both sides have hot data beyond threshold |

### Edge Cases

1. **Composite fact keys** — `(symbol, event_time)` tuples in `NOT IN` subqueries. Trino supports row value constructors.
2. **Dimension deleted vs updated** — INNER JOIN treats both the same (re-evaluate join condition). LEFT JOIN: deletion drives dim columns to NULL.
3. **Cascading dimension changes** — if two dimensions both change in the same scheduler cycle, each join's changed keys independently contribute to the affected set. Union them.
4. **Fact key uniqueness** — rewriter assumes `fact_key` uniquely identifies each row in the result. If it doesn't (e.g. multiple rows per symbol per second), a `ROW_NUMBER()` dedup is required on top.
5. **Join count limit** — DLT caps incremental joins at 2 (max 5). Lukewarm should implement a configurable threshold with a warning beyond which full recompute is forced.

---

## 3. Industry Research: DLT and Snowflake Dynamic Tables

### Databricks Delta Live Tables (DLT)

**Two distinct table types with different incremental models:**

- **Streaming Tables** — backed by Spark Structured Streaming. Offset-based checkpointing. Processes each new row exactly once. Stream-static joins are fast but **do not retroactively re-join when the dimension changes** — historical rows keep stale dimension values. Correcting requires a full refresh.

- **Materialized Views** — powered by the Enzyme engine. Uses Delta CDF (Change Data Feed) + row tracking (stable UUIDs per row). Enzyme evaluates a cost model to choose between incremental and full refresh. Dimension changes correctly trigger re-joins for affected rows.

**Enzyme refresh strategies** (relevant to Lukewarm's strategy classifier):

| Strategy | When Used |
|---|---|
| `APPEND_ONLY` | Source is append-only |
| `ROW_BASED` | Row-level delta merge with row tracking |
| `GROUP_AGGREGATE` | Recompute only affected grouping keys |
| `PARTITION_OVERWRITE` | Overwrite partitions containing changed rows |
| `WINDOW_FUNCTION` | Recompute window for affected partition keys |

**DLT Join Limits:** Default 2 joins for incremental refresh (max 5). Beyond this limit → `NUM_JOINS_THRESHOLD_EXCEEDED` → forced full refresh. A real constraint for star schemas with 4–6 dimensions.

**DLT Key Limitation for Lukewarm:** Streaming tables silently serve stale dimension data when dimensions change. This is the correctness gap Lukewarm is designed to solve.

---

### Snowflake Dynamic Tables

**Change detection:** Uses Snowflake time travel + internal streams. Each base table row has a stable `METADATA$ROW_ID`. Changes are captured as DELETE + INSERT pairs. Requires `DATA_RETENTION_TIME_IN_DAYS > 0`.

**Refresh modes:**
- `INCREMENTAL` — read change stream since last refresh, apply delta. Requires all upstream objects to support change tracking.
- `FULL` — re-execute full query, replace all data.
- `AUTO` (default) — Snowflake chooses at creation time; decision is fixed. Unsupported SQL changes cause failure, not graceful fallback.

**Per-operator incremental behavior:**
- `INNER JOIN` — bilateral: `left_delta JOIN right_full` ∪ `right_delta JOIN left_full`
- `OUTER JOIN` — equi-joins only. Put higher-change-frequency table on the LEFT side.
- `GROUP BY` — recomputes only grouping keys containing at least one changed row
- `WINDOW FUNCTIONS` — recomputes for every partition key containing a changed row; requires explicit `PARTITION BY`
- `SCALAR AGGREGATES` (no GROUP BY) — fully recomputed on any input change

**The 5% cliff:** Snowflake explicitly documents that incremental refresh becomes **less efficient than full recompute above ~5% change rate**. The overhead of change-set computation + bilateral join scanning can exceed the cost of a full table scan. This is the hard number behind Lukewarm's hot-delta threshold / circuit breaker.

**Lag model:** Each dynamic table has a `TARGET_LAG`. With `TARGET_LAG = DOWNSTREAM`, a table only refreshes when a downstream table needs it — equivalent to Lukewarm's skip-if-unchanged propagation through the DAG.

**Consistency:** Time travel snapshot isolation across the entire DAG at refresh time. All upstream tables are read at the same data timestamp.

**Key Limitation for Lukewarm:** A single `FULL`-mode node in the DAG breaks incremental propagation for all descendants. Lukewarm's cold snapshot approach doesn't have this constraint — cold is always a complete pre-materialized result regardless of how the upstream was computed.

---

### DLT vs Snowflake vs Lukewarm Comparison

| Dimension | DLT Streaming Table | DLT Materialized View | Snowflake Dynamic Table | Lukewarm |
|---|---|---|---|---|
| Incremental engine | Spark Structured Streaming checkpoints | Enzyme + Delta CDF + row tracking | Time travel + internal streams | Iceberg snapshot IDs + incremental file scan |
| Dimension change handling | Stale (no recompute) | Correct (auto re-join) | Correct (bilateral delta) | Correct (re-join affected cold rows) |
| Join limit | Unlimited (but stale) | 2 default, 5 max | No stated limit (equi-joins only for outer) | Configurable threshold |
| 5% change cliff | No (streaming) | No (Enzyme cost model) | Yes (explicit) | Circuit breaker (configurable) |
| Engine lock-in | Databricks | Databricks | Snowflake | None (SQL rewriting, any engine) |
| Iceberg native | No (Delta) | No (Delta) | No (Snowflake internal) | Yes |
| Query freshness | As of last micro-batch | As of last refresh | As of last refresh lag | Always current (read-time merge) |

---

## 4. Competitive Landscape

### Summary Comparison

| System | Read-time Hot/Cold Merge | Iceberg Native | Skip-if-Snapshot-Unchanged | Engine-Agnostic | SQL Model DAG |
|---|---|---|---|---|---|
| **Lukewarm** | Yes (core design) | Yes | Yes (planned) | Yes (Trino, pluggable) | Yes (`ref()`) |
| StarRocks AMV | No (write-side refresh) | Source only | Yes (partition-level) | No | No |
| DuckDB | No IVM | Yes (read+write) | No | Yes (no framework) | No |
| Hudi MoR | Yes (base+delta at read) | No (competing format) | No | Partially (engine readers) | No |
| Paimon | Yes (LSM levels at read) | Compatibility shim | No | Flink/Spark | No |
| Fluss + Iceberg | Yes (union read) | Yes (cold tier) | No (continuous) | Flink only | No |
| Materialize | No (always current) | No | N/A | No | No |
| RisingWave | No (always current) | Yes (source+sink) | N/A | No | No |
| dbt | No (write-side only) | Via adapters | No | Yes (adapters) | Yes (`ref()`) |
| AWS Glue MV | No (incremental write) | Yes (native) | Effectively yes | No (Spark/AWS) | No |
| Hive/Cloudera MV | No (rebuild on write) | Yes (source) | Implicitly | No (Hive only) | No |
| MS Fabric MLV | No (incremental write) | No (Delta) | Yes (Delta log) | No (Fabric/Spark) | No |

---

### StarRocks

Most mature open-source competitor for the use case. Async Materialized Views (AMVs) over Iceberg sources:
- Tracks Iceberg snapshot IDs at partition level — same signal Lukewarm uses
- Skips refresh if no snapshot change
- Transparent query rewrite: routes ad-hoc queries to the pre-materialized MV automatically
- **Does not** do read-time hot/cold merge — if refresh hasn't run, queries hit stale cold data
- MVs stored in StarRocks' internal format, not as Iceberg tables
- StarRocks is the query engine — not engine-agnostic

**2026 roadmap:** true IVM path for append-only Iceberg sources.

---

### Apache Hudi MoR — Closest Structural Analog

Hudi's Merge-on-Read table type is architecturally the closest analog to Lukewarm at the storage layer:
- **Base files** (Parquet) = cold layer (last compacted snapshot)
- **Delta log files** (Avro) = hot layer (writes since last compaction)
- Snapshot queries merge base + delta at read time — same hot/cold merge concept

**Key differences:**
- Operates at the raw data layer, not the SQL transformation model layer
- Delta log contains raw row changes, not derived computation
- No DAG of transformations, no `ref()`, no scheduler
- Competing table format — cannot apply to Iceberg tables
- Engine-specific readers required (not plain SQL)

---

### Fluss + Iceberg — Closest Architectural Analog (New, 2025)

Apache Fluss (incubating, Alibaba/Ververica) formalizes a hot/cold tiering architecture:
- **Hot tier (Fluss):** sub-second latency columnar streaming storage
- **Cold tier (Iceberg):** long-term compacted Parquet storage
- **Union read:** Flink queries execute `UNION` of Fluss (hot) + Iceberg (cold) at query time

This is literally the same architectural pattern as Lukewarm — but:
- Operates at raw ingestion layer, not derived SQL model layer
- No DAG of transformations
- Flink-only (Trino support not yet available)
- Requires running a Fluss cluster

---

### dbt — Closest Framework Analog

dbt has the DAG (`ref()` syntax, topological sort) and the model files. But:
- Incremental materialization is **write-side** — computes delta and writes it. No read-time merge.
- No concept of serving a query via merged cold+hot at query time
- No Iceberg snapshot ID change detection — no built-in skip-if-unchanged
- `incremental` strategy on Iceberg works via `MERGE INTO` through adapters

dbt is the closest framework analog. Lukewarm can be thought of as "dbt with lazy read-time hot/cold merge instead of write-side incremental refresh."

---

### AWS Glue Iceberg Materialized Views (November 2025)

Closest managed cloud analog:
- Native Iceberg MVs in Glue Data Catalog
- Uses Iceberg snapshot delta to determine incremental vs full refresh
- Iceberg spec marks MV state as `fresh`, `stale`, `invalid`
- Write-side: refresh job must complete before queries see fresh data
- Spark-only, AWS-only

**Important:** Iceberg's own spec now defines MV states at the catalog level. Lukewarm should align its metadata vocabulary with this standard so Lukewarm-managed models are inspectable by any Iceberg-compatible tool.

---

### Materialize and RisingWave

Both implement continuous IVM (Incremental View Maintenance) using dataflow engines:
- **Materialize:** Differential Dataflow — mathematically exact row-level delta propagation, millisecond latency, always current
- **RisingWave:** similar model, Rust implementation, PostgreSQL-compatible SQL, Iceberg source + sink

Neither does hot/cold merging — they maintain views fully incrementally, always. For large historical datasets this requires maintaining full view state in a state store (expensive). Lukewarm's cold snapshot is a cheap Iceberg read regardless of history size.

Both require writes to flow through them (via Kafka or CDC). Lukewarm works on any Iceberg table written by any engine.

---

### Academic Foundation

- **"Lazy Maintenance of Materialized Views"** — Zhou et al., Microsoft Research, VLDB 2007. Proposes deferring MV maintenance until the view is queried rather than eagerly maintaining it. Directly validates Lukewarm's read-time merge approach.
- **"Maintenance of Materialized Views: Problems, Techniques, and Applications"** — Mumick, ICDE 1995. Foundational survey. Introduces *self-maintainable views* (can be updated using only the delta, without re-reading the base table) — what Lukewarm achieves for append-only sources.
- **Apache Iceberg spec (2024):** Defines MV states (`fresh`, `stale`, `invalid`) at the catalog level. Industry is converging on this standard.

---

## 5. Lukewarm's Differentiators

### What Makes Lukewarm Genuinely Distinct

**1. Read-time lazy merge, not write-side incremental refresh.**
Every production system with a model DAG (dbt, DLT, StarRocks, AWS Glue) performs incremental work at write time and serves cold results. Lukewarm defers the delta merge to query time — queries are always fresh without waiting for a scheduled job to complete. The closest matches (Hudi MoR, Fluss+Iceberg) operate at the raw data layer, not the derived SQL model layer.

**2. Snapshot ID as the cheapest possible change-detection signal.**
Checking whether an Iceberg snapshot ID has changed requires one REST catalog metadata call. No data scanning. StarRocks independently arrived at the same idea for partition-level tracking. Lukewarm applies it at the model level.

**3. Engine-agnostic via SQL rewriting.**
The hot delta + cold merge is expressed as SQL, so it runs on any engine that can read Iceberg (Trino, Spark, DuckDB, Athena). No engine-specific readers required. Every competitor requires their own engine or is tied to a specific platform.

**4. Declarative SQL DAG of derived models over Iceberg.**
The combination of (a) derived/transformed SQL models, (b) DAG dependency resolution, (c) hot/cold snapshot merge at read time is unique. dbt has the DAG but no hot/cold merge. Hudi/Fluss have the hot/cold merge but no derived model DAG.

### Competitive Positioning

```
                    Has SQL Model DAG
                           │
           dbt ────────────┼──────────── Lukewarm
           DLT             │
        StarRocks          │
                           │
Write-side  ───────────────┼─────────────── Read-time
Refresh                    │               Merge
                           │
                           │         Hudi MoR
                           │         Fluss+Iceberg
                           │
                    No SQL Model DAG
```

Lukewarm occupies the top-right quadrant alone.

---

## 6. Build Implications

### Revised Build Order

Research from DLT and Snowflake informs a more precise build sequence:

1. **Model declaration parser** — `.sql` + `.yml` sidecar, validate fact/dim/key declarations
2. **DAG resolver** — topological sort, `DOWNSTREAM` lag propagation (skip if no downstream needs it)
3. **Snapshot tracker** — query `$snapshots` metadata table, compare to SQLite, compute change rate
4. **Strategy classifier** — given query shape and snapshot state, select:
   - `APPEND_ONLY` — source is append-only, no joins
   - `DIMENSION_JOIN` — fact × dimension join with new facts
   - `DIMENSION_CHANGE` — dimension update affecting old fact rows (LEFT or INNER)
   - `GROUP_AGGREGATE` — recompute affected grouping keys only
   - `FORCE_FULL` — change rate exceeds threshold or unsupported SQL construct
5. **Query rewriter** — generates SQL per strategy (cold CTE + hot CTE + merge logic)
6. **Hot-delta threshold** — circuit breaker: if change rate > threshold, force full recompute
7. **Materializer** — executes rewritten SQL via Trino, writes result back to Iceberg
8. **Metadata store** — SQLite schema tracking snapshot IDs, strategies used, rows added/updated/excluded

### Alignment with Iceberg MV Spec

Lukewarm's metadata store should use Iceberg's standard MV state vocabulary:
- `fresh` — result snapshot is current with source snapshots
- `stale` — source has new snapshots since last materialization
- `invalid` — source schema has changed, full recompute required

This ensures Lukewarm-managed models are inspectable by any Iceberg-compatible tool, not just Lukewarm.

### Join Count Threshold

DLT's 2-join default (5 max) is a real production constraint. Lukewarm should implement:
- Default threshold: 3 joins for incremental refresh
- Configurable per model via the `.yml` sidecar
- Exceed threshold → log warning → force `FORCE_FULL` strategy

### Observability Fields for Metadata Store

Per materialization run, track:
```
rows_added        — new rows from hot delta
rows_updated      — cold rows replaced by dimension changes
rows_excluded     — cold rows dropped by INNER JOIN invalidation (important to surface)
strategy_used     — which rewrite strategy was selected
refresh_mode      — incremental | full (was circuit breaker triggered?)
source_change_pct — what % of source rows changed (for 5% cliff monitoring)
duration_ms       — execution time
```
