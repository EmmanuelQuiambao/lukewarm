-- top_movers
--
-- Current volatility rankings across all tracked USDT pairs.
-- Identifies day-trading candidates by 24hr price movement and volume.
--
-- Hot + cold pattern:
--   cold — last materialized snapshot of rankings
--   hot  — ticker updates since last snapshot (prices moving in real time)
--   lukewarm query — current rankings merged from both, no full recompute

SELECT
    symbol,
    last_price,
    price_change_pct,
    high_24h,
    low_24h,
    ROUND(high_24h - low_24h, 4)                                AS range_24h,
    ROUND((high_24h - low_24h) / NULLIF(low_24h, 0) * 100, 2)  AS range_pct,
    ROUND(quote_volume_24h / 1e6, 2)                            AS volume_usdt_m,
    num_trades_24h,
    event_time
FROM {{ ref('ticker') }}
WHERE ABS(price_change_pct) > 3.0
  AND quote_volume_24h      > 10000000   -- $10M+ 24hr USDT volume
ORDER BY ABS(price_change_pct) DESC
LIMIT 50
