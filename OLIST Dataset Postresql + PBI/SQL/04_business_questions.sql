-- Purpose:
-- Answer the 13 business questions 
--
-- General rules:
-- * Revenue = item price, excluding freight.
-- * Revenue excludes canceled and unavailable orders.
-- * Delivery analysis uses delivered orders.
-- * Trend analysis uses 2017-01-01 through 2018-08-31.
-- * Customer-level analysis uses customer_unique_id.


-- ============================================================
-- Q1. How is monthly revenue changing over time?
-- MoM = month-over-month
-- YoY = year-over-year
-- ============================================================

WITH monthly AS (
    SELECT
        DATE_TRUNC('month', order_date)::date AS month,
        SUM(item_value) AS revenue,
        COUNT(*) AS orders
    FROM v_orders
    WHERE order_status NOT IN ('canceled', 'unavailable')
      AND order_date >= DATE '2017-01-01'
      AND order_date < DATE '2018-09-01'
    GROUP BY 1
)
SELECT
    month,
    ROUND(revenue, 2) AS revenue,
    orders,

    ROUND(
        100.0
        * (
            revenue
            - LAG(revenue) OVER (ORDER BY month)
        )
        / NULLIF(
            LAG(revenue) OVER (ORDER BY month),
            0
        ),
        1
    ) AS mom_pct,

    ROUND(
        100.0
        * (
            revenue
            - LAG(revenue, 12) OVER (ORDER BY month)
        )
        / NULLIF(
            LAG(revenue, 12) OVER (ORDER BY month),
            0
        ),
        1
    ) AS yoy_pct

FROM monthly
ORDER BY month;


-- ============================================================
-- Q2. Which product categories generate approximately 80% of revenue?
-- ============================================================

SELECT
    category,
    ROUND(revenue, 0) AS revenue,
    pct,
    cum_pct
FROM v_pareto
ORDER BY revenue DESC;


-- Find the categories required to reach approximately 80%.
SELECT
    COUNT(*) AS categories_to_reach_80pct
FROM v_pareto
WHERE cum_pct <= 80;


-- ============================================================
-- Q3. When are customers most active?
-- Day and hour
-- ============================================================

-- Orders by day of week.
SELECT
    order_dow,
    COUNT(*) AS total_orders
FROM v_orders
GROUP BY order_dow
ORDER BY order_dow;

-- Orders by hour.
SELECT
    order_hour,
    COUNT(*) AS total_orders
FROM v_orders
GROUP BY order_hour
ORDER BY total_orders DESC;

-- Day/hour matrix for a Power BI heatmap.
SELECT
    order_dow,
    order_hour,
    COUNT(*) AS total_orders
FROM v_orders
GROUP BY order_dow, order_hour
ORDER BY order_dow, order_hour;


-- ============================================================
-- Q4. How strongly do delivery delays affect customer ratings?
-- ============================================================

SELECT
    delay_bucket,
    COUNT(*) AS orders,
    ROUND(AVG(review_score), 2) AS avg_rating,
    ROUND(
        100.0 * AVG((review_score <= 2)::INT),
        1
    ) AS pct_bad_rating
FROM v_orders
WHERE order_status = 'delivered'
  AND delay_bucket IS NOT NULL
  AND review_score IS NOT NULL
GROUP BY delay_bucket
ORDER BY delay_bucket;


-- ============================================================
-- Q5. Which customer states have the worst delivery performance?
-- ============================================================

SELECT
    customer_state,
    COUNT(*) AS orders,
    ROUND(AVG(delivery_days), 1) AS avg_delivery_days,
    ROUND(
        100.0 * AVG((delay_days > 0)::INT),
        1
    ) AS pct_late,
    ROUND(
        100.0 * SUM(freight_value)
        / NULLIF(SUM(item_value), 0),
        1
    ) AS freight_pct_of_price
FROM v_orders
WHERE order_status = 'delivered'
  AND delay_days IS NOT NULL
GROUP BY customer_state
HAVING COUNT(*) >= 100
ORDER BY pct_late DESC;


-- ============================================================
-- Q6. Which sellers perform best and which are at risk?
-- ============================================================

SELECT
    *,
    RANK() OVER (
        ORDER BY revenue DESC
    ) AS revenue_rank,
    RANK() OVER (
        ORDER BY avg_rating DESC
    ) AS rating_rank
FROM v_seller
ORDER BY revenue DESC;

-- High-revenue sellers with weaker operational performance.
SELECT
    seller_id,
    seller_state,
    orders,
    ROUND(revenue, 2) AS revenue,
    avg_rating,
    pct_late
FROM v_seller
WHERE revenue >= (
    SELECT PERCENTILE_CONT(0.75)
           WITHIN GROUP (ORDER BY revenue)
    FROM v_seller
)
ORDER BY pct_late DESC, avg_rating ASC;


-- ============================================================
-- Q7. What percentage of customers make repeat purchases?
-- ============================================================

SELECT
    customer_type,
    customers,
    pct
FROM v_repeat
ORDER BY customers DESC;

-- Distribution of the number of orders per customer.
SELECT
    total_order,
    COUNT(*) AS customers
FROM (
    SELECT
        customer_unique_id,
        COUNT(*) AS total_order
    FROM v_orders
    WHERE order_status NOT IN ('canceled', 'unavailable')
    GROUP BY customer_unique_id
) AS customer_order_counts
GROUP BY total_order
ORDER BY total_order;


-- ============================================================
-- Q8. How can customers be segmented using RFM analysis?
-- ============================================================

SELECT
    segment,
    COUNT(*) AS customers,
    ROUND(AVG(monetary), 2) AS avg_spend,
    ROUND(AVG(recency_days), 0) AS avg_recency_days
FROM v_rfm
GROUP BY segment
ORDER BY customers DESC;

-- Detailed RFM table for Power BI.
SELECT *
FROM v_rfm
ORDER BY segment, monetary DESC;


-- ============================================================
-- Q9. What percentage of customers return in subsequent months?
-- Cohort retention
-- ============================================================

-- Weighted retention summary.
SELECT
    month_index,
    SUM(customers) AS returning_customers,
    ROUND(
        100.0 * SUM(customers)
        / (
            SELECT SUM(customers)
            FROM v_cohort
            WHERE month_index = 0
        ),
        2
    ) AS retention_pct
FROM v_cohort
WHERE month_index IN (1, 2, 3, 6)
GROUP BY month_index
ORDER BY month_index;

-- Full cohort matrix.
SELECT
    cohort_month,
    month_index,
    customers,
    retention_pct
FROM v_cohort
ORDER BY cohort_month, month_index;


-- ============================================================
-- Q10. What are the main payment methods and installment patterns?
-- ============================================================

-- Payment method.
SELECT
    main_payment_type,
    COUNT(*) AS orders,
    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        1
    ) AS pct_orders,
    ROUND(AVG(payment_value), 2) AS avg_order_value,
    ROUND(
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (
            ORDER BY payment_value
        )::NUMERIC,
        2
    ) AS median_order_value
FROM v_orders
WHERE order_status NOT IN ('canceled', 'unavailable')
  AND main_payment_type IS NOT NULL
GROUP BY main_payment_type
ORDER BY orders DESC;

-- Installment groups for credit-card orders.
SELECT
    CASE
        WHEN installments <= 1 THEN '1x'
        WHEN installments BETWEEN 2 AND 5 THEN '2-5x'
        WHEN installments BETWEEN 6 AND 10 THEN '6-10x'
        ELSE '>10x'
    END AS installment_group,
    COUNT(*) AS orders,
    ROUND(AVG(payment_value), 2) AS avg_order_value
FROM v_orders
WHERE main_payment_type = 'credit_card'
  AND order_status NOT IN ('canceled', 'unavailable')
GROUP BY 1
ORDER BY
    CASE
        WHEN MIN(installments) <= 1 THEN 1
        WHEN MIN(installments) <= 5 THEN 2
        WHEN MIN(installments) <= 10 THEN 3
        ELSE 4
    END;


-- ============================================================
-- Q11. Does seller-customer distance affect delivery,
--      freight cost, and ratings?
-- ============================================================

-- Distance buckets.
SELECT
    CASE
        WHEN distance_km < 100 THEN '1. < 100 km'
        WHEN distance_km < 500 THEN '2. 100-500 km'
        WHEN distance_km < 1000 THEN '3. 500-1000 km'
        WHEN distance_km < 2000 THEN '4. 1000-2000 km'
        ELSE '5. > 2000 km'
    END AS distance_bucket,

    COUNT(*) AS items,
    ROUND(AVG(delivery_days), 1) AS avg_delivery_days,
    ROUND(AVG(freight_value), 2) AS avg_freight,
    ROUND(AVG(review_score), 2) AS avg_rating,
    ROUND(
        100.0 * AVG((delay_days > 0)::INT),
        1
    ) AS pct_late

FROM v_shipping
GROUP BY 1
ORDER BY 1;

-- Same-state versus cross-state shipping.
SELECT
    CASE
        WHEN customer_state = seller_state
            THEN 'Same State'
        ELSE 'Cross State'
    END AS shipping_type,

    COUNT(*) AS items,
    ROUND(AVG(delivery_days), 1) AS avg_delivery_days,
    ROUND(AVG(freight_value), 2) AS avg_freight,
    ROUND(AVG(review_score), 2) AS avg_rating

FROM v_shipping
GROUP BY 1;


-- ============================================================
-- Q12. Which product categories have the lowest ratings,
--      and are they associated with late delivery?
-- ============================================================

SELECT
    category,
    orders,
    avg_rating,
    pct_bad_rating,
    pct_late
FROM v_category_rating
ORDER BY avg_rating ASC
LIMIT 10;

-- Overall benchmark.
SELECT
    ROUND(AVG(o.review_score), 2) AS overall_avg_rating,
    ROUND(
        100.0 * AVG((o.delay_days > 0)::INT),
        1
    ) AS overall_pct_late
FROM v_order_items oi
JOIN v_orders o
    ON oi.order_id = o.order_id
WHERE oi.order_status = 'delivered'
  AND o.review_score IS NOT NULL;


-- ============================================================
-- Q13. Which stage of delivery takes the longest?
-- ============================================================

-- Compare delivery stages by on-time status.
SELECT
    shipping_status,
    COUNT(*) AS orders,
    ROUND(AVG(approve_hours)::NUMERIC, 2) AS avg_approval_hours,
    ROUND(AVG(handling_days)::NUMERIC, 2) AS avg_handling_days,
    ROUND(AVG(transit_days)::NUMERIC, 2) AS avg_transit_days,
    ROUND(AVG(total_days)::NUMERIC, 2) AS avg_total_days
FROM v_delivery_timeline
GROUP BY shipping_status
ORDER BY shipping_status;

-- Overall average and median approval time.
SELECT
    ROUND(AVG(approve_hours)::NUMERIC, 2)
        AS avg_approval_hours,

    ROUND(
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (
            ORDER BY approve_hours
        )::NUMERIC,
        2
    ) AS median_approval_hours,

    ROUND(AVG(handling_days)::NUMERIC, 2)
        AS avg_handling_days,

    ROUND(AVG(transit_days)::NUMERIC, 2)
        AS avg_transit_days,

    ROUND(AVG(total_days)::NUMERIC, 2)
        AS avg_total_days

FROM v_delivery_timeline;


-- ============================================================
-- Portfolio-ready KPI checks
-- ============================================================

-- Total revenue for the main analysis period.
SELECT
    ROUND(SUM(item_value), 2) AS total_revenue,
    COUNT(*) AS total_orders,
    ROUND(
        SUM(item_value) / NULLIF(COUNT(*), 0),
        2
    ) AS average_order_value
FROM v_orders
WHERE order_status NOT IN ('canceled', 'unavailable')
  AND order_date >= DATE '2017-01-01'
  AND order_date < DATE '2018-09-01';

-- Overall delivered-order rating and late-delivery rate.
SELECT
    ROUND(AVG(review_score), 2) AS average_rating,
    ROUND(
        100.0 * AVG((delay_days > 0)::INT),
        1
    ) AS late_delivery_pct
FROM v_orders
WHERE order_status = 'delivered'
  AND review_score IS NOT NULL;
