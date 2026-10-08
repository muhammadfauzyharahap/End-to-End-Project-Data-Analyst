-- Purpose:
-- Build reusable analytical views from the raw Olist tables.
--
-- Design principle:
-- Aggregate one-to-many tables before joining them to the one-row-per-order
-- table. This prevents revenue, payment, and review metrics from being
-- multiplied by JOINs.

-- ============================================================
-- 0. Remove old views
-- ============================================================

DROP VIEW IF EXISTS
    v_state_geo,
    v_category_rating,
    v_repeat,
    v_pareto,
    v_cohort,
    v_rfm,
    v_seller,
    v_delivery_timeline,
    v_shipping,
    v_order_items,
    v_orders
CASCADE;


-- ============================================================
-- 1. v_orders
-- One row = one order
-- ============================================================

CREATE OR REPLACE VIEW v_orders AS
WITH item_summary AS (
    SELECT
        order_id,
        SUM(price) AS item_value,
        SUM(freight_value) AS freight_value,
        COUNT(*) AS item_count
    FROM order_items
    GROUP BY order_id
),
payment_summary AS (
    SELECT
        order_id,
        SUM(payment_value) AS payment_value,
        MAX(payment_installments) AS installments,
        (ARRAY_AGG(
            payment_type
            ORDER BY payment_value DESC
        ))[1] AS main_payment_type
    FROM order_payments
    GROUP BY order_id
),
review_summary AS (
    SELECT
        order_id,
        ROUND(AVG(review_score), 2) AS review_score
    FROM order_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    c.customer_unique_id,
    c.customer_state,
    o.order_status,
    o.order_purchase_timestamp,
    o.order_purchase_timestamp::date AS order_date,

    EXTRACT(HOUR FROM o.order_purchase_timestamp)::INT
        AS order_hour,

    EXTRACT(ISODOW FROM o.order_purchase_timestamp)::INT
        || '-' ||
    TO_CHAR(o.order_purchase_timestamp, 'Dy')
        AS order_dow,

    (
        o.order_delivered_customer_date::date
        - o.order_purchase_timestamp::date
    ) AS delivery_days,

    (
        o.order_delivered_customer_date::date
        - o.order_estimated_delivery_date::date
    ) AS delay_days,

    CASE
        WHEN o.order_delivered_customer_date IS NULL
            THEN NULL
        WHEN o.order_delivered_customer_date::date
             <= o.order_estimated_delivery_date::date
            THEN '1. On Time'
        WHEN o.order_delivered_customer_date::date
             - o.order_estimated_delivery_date::date <= 3
            THEN '2. Late 1-3 Days'
        WHEN o.order_delivered_customer_date::date
             - o.order_estimated_delivery_date::date <= 7
            THEN '3. Late 4-7 Days'
        ELSE '4. Late > 7 Days'
    END AS delay_bucket,

    i.item_value,
    i.freight_value,
    i.item_count,

    p.payment_value,
    p.installments,
    p.main_payment_type,

    r.review_score

FROM orders o
JOIN customers c
    ON o.customer_id = c.customer_id
LEFT JOIN item_summary i
    ON o.order_id = i.order_id
LEFT JOIN payment_summary p
    ON o.order_id = p.order_id
LEFT JOIN review_summary r
    ON o.order_id = r.order_id;


-- ============================================================
-- 2. v_order_items
-- One row = one order item
-- ============================================================

CREATE OR REPLACE VIEW v_order_items AS
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    oi.price,
    oi.freight_value,

    o.order_status,
    o.order_purchase_timestamp::date AS order_date,

    c.customer_state,
    c.customer_zip_code_prefix AS customer_zip,

    s.seller_state,
    s.seller_zip_code_prefix AS seller_zip,

    COALESCE(
        t.product_category_name_english,
        p.product_category_name,
        'unknown'
    ) AS category

FROM order_items oi
JOIN orders o
    ON oi.order_id = o.order_id
JOIN customers c
    ON o.customer_id = c.customer_id
JOIN products p
    ON oi.product_id = p.product_id
LEFT JOIN sellers s
    ON oi.seller_id = s.seller_id
LEFT JOIN product_category_name_translation t
    ON p.product_category_name = t.product_category_name;


-- ============================================================
-- 3. v_shipping
-- One row = one order item with seller/customer geography
-- ============================================================

CREATE OR REPLACE VIEW v_shipping AS
SELECT
    oi.order_id,
    oi.seller_id,
    oi.customer_state,
    oi.seller_state,
    oi.order_date,
    oi.price,
    oi.freight_value,

    o.delivery_days,
    o.delay_days,
    o.review_score,

    6371 * 2 * ASIN(
        SQRT(
            POWER(
                SIN(RADIANS(gc.lat - gs.lat) / 2),
                2
            )
            +
            COS(RADIANS(gs.lat))
            * COS(RADIANS(gc.lat))
            * POWER(
                SIN(RADIANS(gc.lng - gs.lng) / 2),
                2
            )
        )
    ) AS distance_km

FROM v_order_items oi
JOIN v_orders o
    ON oi.order_id = o.order_id
JOIN geo_clean gc
    ON oi.customer_zip = gc.zip
JOIN geo_clean gs
    ON oi.seller_zip = gs.zip
WHERE o.order_status = 'delivered';


-- ============================================================
-- 4. v_delivery_timeline
-- One row = one valid delivered order
-- ============================================================

CREATE OR REPLACE VIEW v_delivery_timeline AS
SELECT
    o.order_id,
    c.customer_state,
    o.order_purchase_timestamp::date AS order_date,

    EXTRACT(
        EPOCH FROM (
            o.order_approved_at
            - o.order_purchase_timestamp
        )
    ) / 3600 AS approve_hours,

    EXTRACT(
        EPOCH FROM (
            o.order_delivered_carrier_date
            - o.order_approved_at
        )
    ) / 86400 AS handling_days,

    EXTRACT(
        EPOCH FROM (
            o.order_delivered_customer_date
            - o.order_delivered_carrier_date
        )
    ) / 86400 AS transit_days,

    EXTRACT(
        EPOCH FROM (
            o.order_delivered_customer_date
            - o.order_purchase_timestamp
        )
    ) / 86400 AS total_days,

    CASE
        WHEN o.order_delivered_customer_date::date
             > o.order_estimated_delivery_date::date
            THEN 'Late'
        ELSE 'On Time'
    END AS shipping_status

FROM orders o
JOIN customers c
    ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
  AND o.order_approved_at IS NOT NULL
  AND o.order_delivered_carrier_date IS NOT NULL
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_delivered_carrier_date >= o.order_approved_at
  AND o.order_delivered_customer_date >= o.order_delivered_carrier_date;


-- ============================================================
-- 5. v_seller
-- Seller performance, minimum 30 delivered orders
-- ============================================================

CREATE OR REPLACE VIEW v_seller AS
SELECT
    oi.seller_id,
    MAX(oi.seller_state) AS seller_state,
    COUNT(DISTINCT oi.order_id) AS orders,
    SUM(oi.price) AS revenue,
    ROUND(AVG(o.review_score), 2) AS avg_rating,
    ROUND(
        100.0 * AVG((o.delay_days > 0)::INT),
        1
    ) AS pct_late
FROM v_order_items oi
JOIN v_orders o
    ON oi.order_id = o.order_id
WHERE oi.order_status = 'delivered'
GROUP BY oi.seller_id
HAVING COUNT(DISTINCT oi.order_id) >= 30;


-- ============================================================
-- 6. v_rfm
-- Customer RFM segmentation
-- ============================================================

CREATE OR REPLACE VIEW v_rfm AS
WITH rfm AS (
    SELECT
        customer_unique_id,
        (
            DATE '2018-09-01'
            - MAX(order_date)
        ) AS recency_days,
        COUNT(*) AS frequency,
        SUM(item_value) AS monetary
    FROM v_orders
    WHERE order_status NOT IN ('canceled', 'unavailable')
      AND item_value IS NOT NULL
    GROUP BY customer_unique_id
),
scored AS (
    SELECT
        *,
        NTILE(4) OVER (
            ORDER BY recency_days DESC
        ) AS r_score,
        NTILE(4) OVER (
            ORDER BY monetary
        ) AS m_score
    FROM rfm
)
SELECT
    *,
    CASE
        WHEN r_score >= 3 AND m_score >= 3
            THEN 'Champions'
        WHEN r_score >= 3 AND m_score < 3
            THEN 'New / Low Value'
        WHEN r_score < 3 AND m_score >= 3
            THEN 'Big Spenders at Risk'
        ELSE 'Inactive'
    END AS segment
FROM scored;


-- ============================================================
-- 7. v_cohort
-- Monthly customer retention
-- ============================================================

CREATE OR REPLACE VIEW v_cohort AS
WITH first_order AS (
    SELECT
        customer_unique_id,
        DATE_TRUNC(
            'month',
            MIN(order_date)
        )::date AS cohort_month
    FROM v_orders
    WHERE order_status NOT IN ('canceled', 'unavailable')
    GROUP BY customer_unique_id
),
activity AS (
    SELECT DISTINCT
        f.cohort_month,
        f.customer_unique_id,
        (
            (
                EXTRACT(YEAR FROM o.order_date) * 12
                + EXTRACT(MONTH FROM o.order_date)
            )
            -
            (
                EXTRACT(YEAR FROM f.cohort_month) * 12
                + EXTRACT(MONTH FROM f.cohort_month)
            )
        )::INT AS month_index
    FROM v_orders o
    JOIN first_order f
        ON o.customer_unique_id = f.customer_unique_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),
cohort_counts AS (
    SELECT
        cohort_month,
        month_index,
        COUNT(*) AS customers
    FROM activity
    WHERE cohort_month >= DATE '2017-01-01'
      AND cohort_month < DATE '2018-09-01'
    GROUP BY cohort_month, month_index
)
SELECT
    cohort_month,
    month_index,
    customers,
    ROUND(
        100.0 * customers
        / MAX(customers) OVER (
            PARTITION BY cohort_month
        ),
        2
    ) AS retention_pct
FROM cohort_counts;


-- ============================================================
-- 8. v_pareto
-- Category revenue and cumulative revenue share
-- ============================================================

CREATE OR REPLACE VIEW v_pareto AS
WITH category_revenue AS (
    SELECT
        category,
        SUM(price) AS revenue
    FROM v_order_items
    WHERE order_status NOT IN ('canceled', 'unavailable')
    GROUP BY category
)
SELECT
    category,
    revenue,
    ROUND(
        100.0 * revenue
        / SUM(revenue) OVER (),
        2
    ) AS pct,
    ROUND(
        100.0
        * SUM(revenue) OVER (
            ORDER BY revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING
            AND CURRENT ROW
        )
        / SUM(revenue) OVER (),
        2
    ) AS cum_pct
FROM category_revenue;


-- ============================================================
-- 9. v_repeat
-- One-time vs repeat customers
-- ============================================================

CREATE OR REPLACE VIEW v_repeat AS
WITH customer_orders AS (
    SELECT
        customer_unique_id,
        COUNT(*) AS total_order
    FROM v_orders
    WHERE order_status NOT IN ('canceled', 'unavailable')
    GROUP BY customer_unique_id
)
SELECT
    CASE
        WHEN total_order = 1 THEN 'One-time'
        ELSE 'Repeat'
    END AS customer_type,
    COUNT(*) AS customers,
    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        2
    ) AS pct
FROM customer_orders
GROUP BY 1;


-- ============================================================
-- 10. v_category_rating
-- Category rating and late-delivery rate
-- Minimum 100 orders
-- ============================================================

CREATE OR REPLACE VIEW v_category_rating AS
SELECT
    oi.category,
    COUNT(DISTINCT oi.order_id) AS orders,
    ROUND(AVG(o.review_score), 2) AS avg_rating,
    ROUND(
        100.0 * AVG((o.review_score <= 2)::INT),
        1
    ) AS pct_bad_rating,
    ROUND(
        100.0 * AVG((o.delay_days > 0)::INT),
        1
    ) AS pct_late
FROM v_order_items oi
JOIN v_orders o
    ON oi.order_id = o.order_id
WHERE oi.order_status = 'delivered'
  AND o.review_score IS NOT NULL
GROUP BY oi.category
HAVING COUNT(DISTINCT oi.order_id) >= 100;


-- ============================================================
-- 11. v_state_geo
-- Representative coordinates for Power BI maps
-- ============================================================

CREATE OR REPLACE VIEW v_state_geo AS
SELECT
    state,
    AVG(lat) AS lat,
    AVG(lng) AS lng
FROM geo_clean
GROUP BY state;


-- ============================================================
-- Validation checks
-- ============================================================

SELECT COUNT(*) AS v_orders_rows
FROM v_orders;

SELECT
    COUNT(*) AS v_order_items_rows
FROM v_order_items;

SELECT
    COUNT(*) AS v_seller_rows
FROM v_seller;

SELECT
    COUNT(*) AS v_rfm_rows
FROM v_rfm;

SELECT
    COUNT(*) AS v_shipping_rows
FROM v_shipping;

-- Critical anti-duplication check:
SELECT
    COUNT(*) AS v_orders_rows,
    SUM(item_value) AS view_item_revenue
FROM v_orders;

SELECT
    SUM(price) AS raw_item_revenue
FROM order_items;

-- view_item_revenue should equal raw_item_revenue.
