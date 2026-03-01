-- Example Lukewarm model
-- This model produces a denormalized sales view by joining the fact
-- table with its dimension tables. Lukewarm will materialize this
-- and rewrite it at read time to merge cold + hot data.

SELECT
    t.transaction_id,
    t.trans_date,
    t.sale_price,
    s.store_id,
    s.city,
    s.state,
    s.region,
    c.category,
    c.vendor,
    c.cost,
    t.sale_price - c.cost AS gross_margin
FROM {{ ref('sales_transactions') }} t
JOIN {{ ref('stores') }}  s ON t.store_id = s.id
JOIN {{ ref('catalog') }} c ON t.item_id  = c.id
