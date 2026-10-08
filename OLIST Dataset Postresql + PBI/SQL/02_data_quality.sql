-- Purpose:
-- Validate the raw Olist tables before building analytical views.
-- Run this file AFTER importing all nine CSV files.
-- ============================================================
-- 1. Row-count validation
-- ============================================================

SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews', COUNT(*) FROM order_reviews
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'sellers', COUNT(*) FROM sellers
UNION ALL SELECT 'translation', COUNT(*) FROM product_category_name_translation
UNION ALL SELECT 'geolocation', COUNT(*) FROM geolocation
ORDER BY table_name;

-- Expected:
-- customers 99,441
-- orders 99,441
-- order_items 112,650
-- order_payments 103,886
-- order_reviews 99,224
-- products 32,951
-- sellers 3,095
-- translation 71
-- geolocation 1,000,163


-- ============================================================
-- 2. Order-status distribution
-- ============================================================

SELECT
    order_status,
    COUNT(*) AS order_count
FROM orders
GROUP BY order_status
ORDER BY order_count DESC;

-- Business rule:
-- Revenue analysis excludes canceled and unavailable orders.
-- Delivery analysis uses delivered orders.


-- ============================================================
-- 3. Order-date consistency checks
-- ============================================================

-- Delivered orders with no delivered-customer date.
SELECT COUNT(*) AS delivered_without_customer_date
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NULL;

-- Non-delivered orders with a delivered-customer date.
SELECT COUNT(*) AS non_delivered_with_customer_date
FROM orders
WHERE order_status <> 'delivered'
  AND order_delivered_customer_date IS NOT NULL;

-- Overall purchase-date range.
SELECT
    MIN(order_purchase_timestamp) AS first_purchase,
    MAX(order_purchase_timestamp) AS last_purchase
FROM orders;

-- Delivered orders where the carrier date occurs before approval.
SELECT COUNT(*) AS invalid_carrier_sequence
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_delivered_carrier_date < order_approved_at;


-- ============================================================
-- 4. Missing values in important order fields
-- ============================================================

SELECT
    COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL) AS missing_purchase_timestamp,
    COUNT(*) FILTER (WHERE order_approved_at IS NULL) AS missing_approved_at,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL) AS missing_carrier_date,
    COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) AS missing_customer_date,
    COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL) AS missing_estimated_date
FROM orders;


-- ============================================================
-- 5. Order-item consistency
-- ============================================================

-- Orders without any item.
SELECT COUNT(*) AS orders_without_items
FROM orders o
LEFT JOIN order_items oi
    ON o.order_id = oi.order_id
WHERE oi.order_id IS NULL;

-- Duplicate order-item identifiers within an order.
SELECT
    order_id,
    order_item_id,
    COUNT(*) AS duplicate_count
FROM order_items
GROUP BY order_id, order_item_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;


-- ============================================================
-- 6. Payment anomalies
-- ============================================================

SELECT
    COUNT(*) FILTER (WHERE payment_installments = 0) AS zero_installments,
    COUNT(*) FILTER (WHERE payment_value = 0) AS zero_payment_value,
    COUNT(*) FILTER (WHERE payment_type = 'not_defined') AS undefined_payment_type
FROM order_payments;


-- ============================================================
-- 7. Multiple reviews and duplicate review IDs
-- ============================================================

SELECT COUNT(*) AS orders_with_multiple_reviews
FROM (
    SELECT order_id
    FROM order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
) AS review_counts;

SELECT
    COUNT(*) - COUNT(DISTINCT review_id) AS duplicate_review_id_rows
FROM order_reviews;


-- ============================================================
-- 8. Product and category quality
-- ============================================================

SELECT
    COUNT(*) FILTER (WHERE product_category_name IS NULL) AS missing_category,
    COUNT(*) FILTER (WHERE product_weight_g IS NULL) AS missing_weight,
    COUNT(*) FILTER (WHERE product_weight_g = 0) AS zero_weight
FROM products;

-- Categories that have no English translation.
SELECT DISTINCT
    p.product_category_name
FROM products p
LEFT JOIN product_category_name_translation t
    ON p.product_category_name = t.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL
ORDER BY p.product_category_name;


-- ============================================================
-- 9. Customer identity check
-- ============================================================

SELECT
    COUNT(DISTINCT customer_id) AS customer_id_count,
    COUNT(DISTINCT customer_unique_id) AS unique_customer_count
FROM customers;

-- IMPORTANT:
-- customer_unique_id is the correct customer-level identifier for
-- repeat-purchase, RFM, and cohort analysis.


-- ============================================================
-- 10. Geolocation quality
-- ============================================================

SELECT
    COUNT(*) AS geolocation_rows,
    COUNT(DISTINCT geolocation_zip_code_prefix) AS unique_zip_codes
FROM geolocation;

SELECT COUNT(*) AS points_outside_expected_brazil_bounds
FROM geolocation
WHERE geolocation_lat NOT BETWEEN -34 AND 6
   OR geolocation_lng NOT BETWEEN -74 AND -30;


-- ============================================================
-- 11. Create the cleaned geolocation table
-- ============================================================
-- One ZIP code can have many geolocation records.
-- We reduce it to one representative point per ZIP code.

DROP TABLE IF EXISTS geo_clean;

CREATE TABLE geo_clean AS
SELECT
    geolocation_zip_code_prefix AS zip,
    AVG(geolocation_lat) AS lat,
    AVG(geolocation_lng) AS lng,
    MODE() WITHIN GROUP (ORDER BY geolocation_state) AS state
FROM geolocation
WHERE geolocation_lat BETWEEN -34 AND 6
  AND geolocation_lng BETWEEN -74 AND -30
GROUP BY geolocation_zip_code_prefix;

CREATE INDEX idx_geo_clean_zip
    ON geo_clean(zip);

SELECT COUNT(*) AS geo_clean_rows
FROM geo_clean;

-- Check ZIP-code coverage for customers and sellers.
SELECT
    (
        SELECT COUNT(*)
        FROM customers c
        LEFT JOIN geo_clean g
            ON c.customer_zip_code_prefix = g.zip
        WHERE g.zip IS NULL
    ) AS customers_without_geo,
    (
        SELECT COUNT(*)
        FROM sellers s
        LEFT JOIN geo_clean g
            ON s.seller_zip_code_prefix = g.zip
        WHERE g.zip IS NULL
    ) AS sellers_without_geo;


-- ============================================================
-- 12. Final data-quality decisions
-- ============================================================
-- 1. Do not modify the raw tables.
-- 2. Exclude canceled and unavailable orders from revenue analysis.
-- 3. Use delivered orders for delivery analysis.
-- 4. Use customer_unique_id for customer-level analysis.
-- 5. Average multiple reviews at order level.
-- 6. Use COALESCE for missing/translated product categories.
-- 7. Use geo_clean for geographic distance analysis.
