# Lukewarm — Infrastructure Considerations

_Last updated: 2026-03-09_

A working reference document covering infrastructure trade-offs and decisions for productionalizing the Lukewarm framework. Covers Kafka, Spark, Flink, and table format selection.

---

## Kafka

### Partitions

Partitions are the unit of parallelism in Kafka. Key properties:

- A topic is split into N partitions — you choose N at creation time
- Message routing: `partition = hash(key) % N`
- No key set → round-robin distribution across partitions
- Partition count can only be **increased**, never decreased — over-provision upfront
- Consumer parallelism is capped by partition count regardless of how many executor cores you have

**Key choice matters:**
- Key by `symbol` → all ticks for that symbol land on the same partition → ordered per symbol
- No key → round-robin → maximum throughput, no ordering guarantees
- Bad key (low cardinality) → hot partition, defeats parallelism

**Symbol bucketing — the middle ground:**
Instead of one partition per symbol (500+ partitions) or no key (no ordering), hash symbols into a fixed bucket count matching executor capacity:

```python
symbol_bucket = hash(symbol) % 16   # 16 buckets = 16 partitions
producer.send(topic, key=str(symbol_bucket), value=message)
```

Benefits:
- Per-symbol ordering preserved within each bucket
- Partition count matches executor cores — no wasted capacity
- Bucket count is a tuning knob independent of symbol count

---

### Scaling for Volume Spikes

**Partition count is the hard ceiling on parallelism.** Even if broker capacity scales automatically, adding brokers redistributes partition leadership but does not create new parallelism for consumers. Size partitions for peak load upfront.

**`maxOffsetsPerTrigger` — read throttle, not batch splitter:**
- Caps how many Kafka offsets a single Spark micro-batch reads
- Does not break one batch into multiple — it limits how far ahead in the Kafka log each trigger reads
- Spike data spreads across multiple trigger intervals rather than crushing one batch
- Ordering maintained via checkpoint: Spark tracks last committed offset per partition, next trigger starts from `last_offset + 1`

```python
.option("maxOffsetsPerTrigger", "100000")
```

**Ordering guarantee:**
- Within a partition: guaranteed (Kafka offset ordering)
- Across partitions: no global ordering — this is a fundamental Kafka property

---

### Managed Kafka Options

| Provider | Scale Up | Scale Down | Notes |
|---|---|---|---|
| MSK Standard | Manual, slow | Risky | You manage brokers |
| MSK Serverless | Automatic | Automatic | Best for spiky traffic |
| Confluent Cloud | Automatic (CKU-based) | Automatic | Richest ecosystem, expensive |
| Redpanda Cloud | Automatic | Automatic | No JVM, lower latency |
| Aiven | Manual tier upgrade | Manual | Multi-cloud, simpler ops |
| Self-managed (Stackable) | Manual | Manual | Full control, full ops burden |

**MSK Serverless** is the natural fit for Binance ticker traffic — predictable baseline with volatility spikes, exactly the pattern serverless handles well.

---

### Kafka vs Kinesis

| | Kafka (MSK) | Kinesis |
|---|---|---|
| Scaling model | Manual / Serverless | Manual resharding / On-Demand |
| Throughput ceiling | Broker-bound (flexible) | Hard 1 MB/s in, 2 MB/s out per shard |
| Scaling down | Not possible (partitions) | Yes — merge shards |
| Retention default | 7 days | 24 hours |
| Maximum retention | Unlimited (disk-bound) | 365 days (extended, extra cost) |
| Spark integration | Native, built into Spark core | Third-party connector JAR |
| Exactly-once with Spark | Well documented | Harder to guarantee |
| Portability | Multi-cloud | AWS-only |
| Ecosystem | Schema Registry, ksqlDB, connectors | Glue Schema Registry only |

**Kinesis resharding:**
```
Start: 4 shards
Spike → split shard 2 into 2a + 2b → 5 shards
Spike subsides → merge 2a + 2b back → 4 shards
```
Kinesis On-Demand does this automatically — the true equivalent of MSK Serverless.

**Kinesis → Spark connectivity:**
- Requires `spark-sql-kinesis` connector (not in Spark core)
- Less mature than Kafka integration — more edge cases, smaller community
- Alternative: Kinesis Firehose → S3 → Spark batch reads (sidesteps connector, adds latency)

**Decision for Lukewarm:** Kafka is the stronger fit. Native Spark integration, longer retention windows, no hard throughput ceiling per partition, and multi-cloud portability. Kinesis is compelling if Lambda or Firehose are your primary consumers.

---

## Spark Structured Streaming

### Executors and Parallelism

Spark parallelism is configured — there is no single default answer:

```
--num-executors 4        # total executor processes
--executor-cores 2       # CPU cores per executor
--executor-memory 4g     # RAM per executor

Total parallelism = num-executors × executor-cores = 8 parallel tasks
```

**Rule of thumb:** `partition count ≈ total executor cores`
- More partitions than cores → tasks queue, multiple rounds needed
- More cores than partitions → idle cores, wasted capacity

Check in the Spark UI (`http://localhost:8082` locally) or from within a job:
```python
spark.sparkContext.defaultParallelism  # total cores across all executors
```

Our local docker-compose Spark worker has **2 cores, 2GB RAM** — sufficient for dev only.

---

### Duplicates and Write Semantics

**Sources of duplicates:**
1. Kafka at-least-once delivery — producer retries can produce duplicate messages
2. Spark task retries — failed tasks re-read the same Kafka offsets
3. Checkpoint/write gap — Spark writes to Iceberg successfully but crashes before committing the checkpoint; on restart it re-processes those offsets

**Mitigation — intra-batch deduplication:**
```python
def write_batch(df, epoch_id):
    df.dropDuplicates(["symbol", "event_time"]) \
      .writeTo("iceberg.crypto.ticker") \
      .append()
```

`dropDuplicates` triggers a shuffle — Spark co-locates rows with matching keys across executors to compare them. For large batches this has network cost.

**Optimization: pre-partition by dedup key**
```python
df.repartition("symbol", "event_time") \
  .dropDuplicates(["symbol", "event_time"])
```

**Best option at scale: push deduplication upstream**
Use `symbol` as the Kafka message key — all ticks for a symbol land on the same partition, read by one Spark task. Intra-partition dedup happens before the shuffle.

**Append vs Merge:**
- **Append** — correct for time-series (each tick is a distinct point-in-time observation)
- **Merge/upsert** — correct for "current state" tables (latest price per symbol)

For `iceberg.crypto.ticker` (analytics, volatility ranking), append is semantically correct.

---

### Handling Hanging Jobs Under Spikes

#### 1. Skewed Partitions
One Kafka partition receives far more data than others — the job cannot complete until the slowest task finishes.

Mitigation:
- `maxOffsetsPerTrigger` bounds the worst-case batch size
- Monitor per-partition lag, not just total lag
- Use salted keys if keying by high-cardinality fields

#### 2. Shuffle Explosions
Large micro-batches under spikes cause shuffle volume to spike — executors exchange excessive data, causing GC pressure or OOM.

Mitigation:
```python
# Tune shuffle partitions (default 200 is often wrong)
spark.conf.set("spark.sql.shuffle.partitions", "auto")  # Spark 3.x AQE

# Enable Adaptive Query Execution
spark.conf.set("spark.sql.adaptive.execution.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
```

#### 3. GC Pressure / OOM
Large batches exhaust executor heap → GC thrashes → tasks slow or die → retries make it worse.

Mitigation:
```
spark.executor.memory=4g
spark.memory.fraction=0.7
spark.executor.extraJavaOptions=-XX:+UseG1GC
```

`maxOffsetsPerTrigger` is the first line of defense — limits batch size before it reaches the executor.

#### 4. Task Speculation
If one task runs significantly slower than peers (straggler), Spark launches a duplicate speculative task and uses whichever finishes first:

```
spark.speculation=true
spark.speculation.multiplier=1.5
spark.speculation.quantile=0.75
```

**Caution:** only enable if writes are idempotent. With `foreachBatch` + `epoch_id`, Iceberg writes are idempotent.

#### 5. Kafka Consumer Timeout
Long micro-batches can cause Kafka consumer poll timeouts:

```
spark.kafka.consumer.poll.ms=120000
spark.kafka.consumer.fetchOffset.numRetries=3
```

#### Defensive Config Summary

```python
spark = SparkSession.builder \
    .config("spark.sql.adaptive.execution.enabled", "true") \
    .config("spark.sql.adaptive.coalescePartitions.enabled", "true") \
    .config("spark.sql.shuffle.partitions", "auto") \
    .config("spark.dynamicAllocation.enabled", "true") \
    .config("spark.dynamicAllocation.minExecutors", "1") \
    .config("spark.dynamicAllocation.maxExecutors", "10") \
    .config("spark.executor.extraJavaOptions", "-XX:+UseG1GC") \
    .getOrCreate()

stream = spark.readStream \
    .option("maxOffsetsPerTrigger", "100000") \
    .option("kafka.max.poll.records", "10000") \
    ...

stream.trigger(processingTime="60 seconds")
```

---

### Auto-scaling on AWS

| Option | Ops Burden | Auto-scale | Streaming Fit | Cost |
|---|---|---|---|---|
| Spark on EKS (DIY) | High | Yes (manual setup) | Good | Lowest |
| EMR on EKS | Medium | Yes (built-in) | Good | Medium |
| EMR Serverless | Low | Yes (automatic) | Good | Medium |
| Glue Streaming | Low | Yes | Limited | High |

**Spark on EKS (DIY):** Use Spark Operator + Karpenter for node auto-scaling + Dynamic Resource Allocation (DRA) for executor auto-scaling. Full control, meaningful ops overhead.

**EMR on EKS:** AWS manages Spark runtime on your EKS cluster. DRA and Karpenter integration built in. Good middle ground.

**EMR Serverless:** No cluster management. Auto-scales per job. Cold start latency (30-60s) is one-time cost for streaming jobs. Recommended for production.

**Recommended path:**
- Dev/staging: Spark on EKS (matches local Stackable setup)
- Production: EMR Serverless (no cluster ops, auto-scales with MSK spikes)

**Fully serverless pipeline:** MSK Serverless + EMR Serverless + Iceberg on S3 — both broker and processor scale automatically, pay for what you use.

---

## Flink vs Spark Structured Streaming

### Core Difference

```
Spark Structured Streaming:  batch engine adapted for streaming
                             micro-batch model (processes chunks at intervals)
                             seconds latency

Flink:                       native streaming engine
                             true event-by-event processing
                             millisecond latency
```

### Comparison

| | Spark Structured Streaming | Flink |
|---|---|---|
| Processing model | Micro-batch | True event-by-event |
| Latency | Seconds | Milliseconds |
| Throughput | Very high | Very high |
| Exactly-once | Yes | Yes (stronger guarantees) |
| State management | Limited | First-class (RocksDB) |
| Windowing | Basic | Rich (tumbling, sliding, session) |
| Iceberg support | Native | Native |
| Kafka integration | Native | Native |
| Unified batch + streaming | Yes | No (streaming only) |
| Learning curve | Lower | Higher |
| AWS managed | EMR | Managed Service for Apache Flink |

### Where Flink Wins

- **Latency:** millisecond event processing vs seconds micro-batch
- **Stateful streaming:** RocksDB-backed state for running aggregations (rolling VWAP, running volatility per symbol)
- **Event time processing:** sophisticated watermarking for late-arriving events
- **Windowed aggregations:** tumbling, sliding, session windows are first-class

### Where Spark Wins

- **Unified batch + streaming:** same code, same cluster for both Lukewarm's materializer and streaming ingestion
- **Simpler ops:** wider community, easier to hire for
- **Complex analytical SQL:** more mature for large-scale analytical queries

### Flink vs Lukewarm

They are **complementary, not competing:**

| | Flink | Lukewarm |
|---|---|---|
| Incremental computation | Yes — native | Yes — hot/cold merge |
| SQL model definition | Flink SQL (continuous) | .sql files (declarative) |
| Dependency DAG | Limited | Yes (ref() system) |
| Ad-hoc queries | No — predefined continuous queries only | Yes — any SQL via Trino |
| Unbounded history joins | Expensive (state grows) | Cheap (cold snapshot in Iceberg) |
| Multi-model orchestration | No | Yes |

**Flink limitation for Lukewarm's use case:** unbounded state. Complex SQL over all-time history requires Flink to maintain ever-growing RocksDB state. Lukewarm's cold snapshot handles unbounded history cheaply — the heavy computation is frozen in Iceberg.

### Recommended Architecture

```
Binance WebSocket
    → Kafka
    → Flink (clean, window, pre-aggregate)    ← Flink's sweet spot
    → Iceberg (raw + pre-aggregated tables)
    → Lukewarm (model DAG, hot/cold merge)    ← Lukewarm's sweet spot
    → Trino (ad-hoc queries, BI tools)
```

### For Lukewarm's Current Use Case

Spark is sufficient for raw tick ingestion. Flink becomes compelling if we add a windowed pre-aggregation layer (e.g. 1-min OHLCV per symbol) before writing to Iceberg.

```
Use Flink when:  continuous low-latency windowed transforms, sub-second latency required
Use Spark when:  unified batch + streaming, complex analytical SQL, simpler ops
```

---

## Table Format Selection: Iceberg vs Hudi vs Delta Lake

### Core Philosophies

```
Iceberg:     snapshot isolation and schema evolution
             optimized for large-scale analytics
             writes are immutable snapshot replacements

Hudi:        record-level upserts and incremental processing
             optimized for CDC and database mutation patterns
             table as a mutable dataset with a changelog

Delta Lake:  analytics + upserts, Databricks-native
             strong SQL semantics
             moving toward open governance (Linux Foundation)
```

### Comparison

| | Apache Iceberg | Apache Hudi | Delta Lake |
|---|---|---|---|
| Primary goal | Analytics, snapshots | Upserts, CDC | Analytics + upserts |
| Record-level upserts | Yes (slower) | First-class, optimized | Good |
| Incremental reads | Snapshot diff | Native (designed for it) | Moderate |
| Table types | Copy-on-Write | CoW + Merge-on-Read | Copy-on-Write |
| Compaction | Manual / scheduled | Automatic (built-in) | Manual |
| Schema evolution | Excellent | Good | Good |
| Catalog support | REST, Hive, Glue, Nessie | Hive, Glue | Unity Catalog |
| Engine lock-in | None | Mostly Spark | Databricks-friendly |
| Open governance | Apache | Apache | Linux Foundation |

### Hudi's Two Table Types

**Copy-on-Write (CoW):**
- Upsert → rewrite entire Parquet file containing that record
- Read: fast (clean files, no merging needed)
- Write: slow (rewrites files on every mutation)
- Use when: read-heavy, batch upserts

**Merge-on-Read (MoR):**
- Upsert → write delta log file (fast write)
- Read: merge base file + delta logs on the fly
- Compaction: async, merges logs into base files periodically
- Use when: write-heavy, high-frequency upserts, near-real-time

> Hudi MoR is conceptually similar to Lukewarm's hot/cold pattern — it bakes incremental merging into the table format itself. The difference is Lukewarm operates at the model/query layer, not the storage format layer.

### When to Use Each

**Iceberg:**
- Append-only / immutable data (events, ticks, logs)
- Complex analytical SQL over large history
- Schema evolution requirements
- Multi-engine, multi-catalog, multi-cloud
- Trino as primary query engine

**Hudi:**
- CDC pipelines (Debezium, DMS → database replication)
- High-frequency record mutations (order status, user profiles)
- Near-real-time upserts with automatic compaction
- Incremental pull consumers (ask for changes since timestamp X)

**Delta Lake:**
- Databricks-native deployments
- Strong SQL upsert semantics with Databricks tooling

### Decision Tree

```
Append-only data (events, ticks, logs)?
    → Iceberg

Replicating a relational DB with UPDATE/DELETE?
    → Hudi

Near-real-time upserts + automatic compaction?
    → Hudi MoR

Complex analytical SQL + broad engine support?
    → Iceberg

Databricks-native stack?
    → Delta Lake
```

### For Lukewarm

**Current use case (ticker data):** Iceberg is correct. Data is append-only, Trino is the query engine, complex analytical SQL is the primary workload.

**Future use case (CDC source tables):** Hudi MoR becomes compelling as a source table format. If Lukewarm models are built on top of tables that update frequently (e.g. user profiles, order state), Hudi's upsert engine handles mutations cheaply and Lukewarm's hot delta stays small.

---

## Summary: Recommended Production Stack

| Layer | Technology | Rationale |
|---|---|---|
| Message broker | MSK Serverless | Auto-scales with Binance traffic spikes |
| Stream processing | EMR Serverless | No cluster ops, scales with MSK |
| Pre-aggregation (optional) | Managed Flink | Windowed transforms before Iceberg |
| Table format | Iceberg | Append-only, analytics, Trino-native |
| Object storage | S3 | MSK + EMR native |
| Catalog | Glue / Hive Metastore | Iceberg REST for local dev |
| Query engine | Trino | Customer-owned, Lukewarm submits via HTTP |
| Framework | Lukewarm | Hot/cold merge, model DAG, ad-hoc SQL |
