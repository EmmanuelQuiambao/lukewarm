-- Initialise the crypto namespace and ticker table in the Iceberg REST catalog.
--
-- Run via:
--   docker exec lukewarm-trino trino --file /etc/trino/scripts/init_crypto_schema.sql

CREATE SCHEMA IF NOT EXISTS iceberg.crypto;

CREATE TABLE IF NOT EXISTS iceberg.crypto.ticker (
    symbol              VARCHAR     COMMENT 'Trading pair, e.g. BTCUSDT',
    last_price          DOUBLE      COMMENT 'Latest trade price (USDT)',
    price_change        DOUBLE      COMMENT '24hr absolute price change',
    price_change_pct    DOUBLE      COMMENT '24hr price change %',
    high_24h            DOUBLE      COMMENT '24hr rolling high',
    low_24h             DOUBLE      COMMENT '24hr rolling low',
    base_volume_24h     DOUBLE      COMMENT '24hr volume in base asset',
    quote_volume_24h    DOUBLE      COMMENT '24hr volume in USDT',
    num_trades_24h      BIGINT      COMMENT '24hr trade count',
    event_time          TIMESTAMP(3) WITH TIME ZONE COMMENT 'Binance event timestamp (UTC)'
)
COMMENT 'Binance all-market ticker stream — raw append-only events'
WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['day(event_time)']
);
