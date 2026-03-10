"""Spark Structured Streaming: crypto.ticker (Kafka) → iceberg.crypto.ticker (Iceberg)

Reads the Binance ticker stream from Kafka and appends records to the
Iceberg table `iceberg.crypto.ticker`, partitioned by year/month/day.

Submit via:
  docker exec lukewarm-spark-master spark-submit \\
    --master spark://spark-master:7077 \\
    --packages org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.2,\\
org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.1,\\
org.apache.iceberg:iceberg-aws-bundle:1.5.2,\\
org.apache.hadoop:hadoop-aws:3.3.4 \\
    /opt/spark/jobs/ticker_to_iceberg.py
"""

from pyspark.sql import SparkSession
from pyspark.sql.functions import col, from_json, timestamp_millis
from pyspark.sql.types import (
    DoubleType,
    LongType,
    StringType,
    StructField,
    StructType,
)

KAFKA_BOOTSTRAP = "kafka:29092"
KAFKA_TOPIC = "crypto.ticker"
ICEBERG_TABLE = "iceberg.crypto.ticker"
CHECKPOINT_PATH = "s3a://lukewarm/checkpoints/ticker_to_iceberg"

TICKER_SCHEMA = StructType([
    StructField("symbol",           StringType(), False),
    StructField("last_price",       DoubleType(), True),
    StructField("price_change",     DoubleType(), True),
    StructField("price_change_pct", DoubleType(), True),
    StructField("high_24h",         DoubleType(), True),
    StructField("low_24h",          DoubleType(), True),
    StructField("base_volume_24h",  DoubleType(), True),
    StructField("quote_volume_24h", DoubleType(), True),
    StructField("num_trades_24h",   LongType(),   True),
    StructField("event_time_ms",    LongType(),   False),
])


def build_spark() -> SparkSession:
    return (
        SparkSession.builder
        .appName("ticker-to-iceberg")
        # Iceberg REST catalog
        .config(
            "spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
        )
        .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog")
        .config("spark.sql.catalog.iceberg.type", "rest")
        .config("spark.sql.catalog.iceberg.uri", "http://iceberg-rest:8181")
        .config("spark.sql.catalog.iceberg.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
        .config("spark.sql.catalog.iceberg.s3.endpoint", "http://minio:9000")
        .config("spark.sql.catalog.iceberg.s3.access-key-id", "minioadmin")
        .config("spark.sql.catalog.iceberg.s3.secret-access-key", "minioadmin")
        .config("spark.sql.catalog.iceberg.s3.path-style-access", "true")
        .config("spark.sql.catalog.iceberg.s3.region", "us-east-1")
        # S3A for checkpoint storage
        .config("spark.hadoop.fs.s3a.endpoint", "http://minio:9000")
        .config("spark.hadoop.fs.s3a.access.key", "minioadmin")
        .config("spark.hadoop.fs.s3a.secret.key", "minioadmin")
        .config("spark.hadoop.fs.s3a.path.style.access", "true")
        .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
        .getOrCreate()
    )


def main() -> None:
    spark = build_spark()
    spark.sparkContext.setLogLevel("WARN")

    raw = (
        spark.readStream
        .format("kafka")
        .option("kafka.bootstrap.servers", KAFKA_BOOTSTRAP)
        .option("subscribe", KAFKA_TOPIC)
        .option("startingOffsets", "latest")
        .option("failOnDataLoss", "false")
        .load()
    )

    parsed = (
        raw
        .select(from_json(col("value").cast("string"), TICKER_SCHEMA).alias("t"))
        .select("t.*")
        .withColumn("event_time", timestamp_millis(col("event_time_ms")))
        .drop("event_time_ms")
    )

    query = (
        parsed.writeStream
        .format("iceberg")
        .outputMode("append")
        .option("checkpointLocation", CHECKPOINT_PATH)
        .toTable(ICEBERG_TABLE)
    )

    query.awaitTermination()


if __name__ == "__main__":
    main()
