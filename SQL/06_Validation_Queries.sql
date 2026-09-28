USE EcommerceDW;
GO

/* =========================================================
   OLIST E-COMMERCE DATA WAREHOUSE
   FINAL VALIDATION QUERIES
   ========================================================= */


/* =========================================================
   1. GOLD ROW COUNTS
   ========================================================= */

SELECT
    'DimCustomer' AS table_name,
    COUNT(*) AS row_count
FROM gold.DimCustomer

UNION ALL

SELECT
    'DimProduct',
    COUNT(*)
FROM gold.DimProduct

UNION ALL

SELECT
    'DimSeller',
    COUNT(*)
FROM gold.DimSeller

UNION ALL

SELECT
    'DimDate',
    COUNT(*)
FROM gold.DimDate

UNION ALL

SELECT
    'FactSales',
    COUNT(*)
FROM gold.FactSales

UNION ALL

SELECT
    'FactPayments',
    COUNT(*)
FROM gold.FactPayments

UNION ALL

SELECT
    'FactDelivery',
    COUNT(*)
FROM gold.FactDelivery;
GO


/* =========================================================
   2. CONTROL TOTALS
   Silver vs Gold
   ========================================================= */

SELECT
    'Silver Order Items' AS source_table,
    COUNT(*) AS row_count,
    SUM(price) AS total_price,
    SUM(freight_value) AS total_freight
FROM silver.order_items

UNION ALL

SELECT
    'Gold FactSales',
    COUNT(*),
    SUM(price),
    SUM(freight_value)
FROM gold.FactSales

UNION ALL

SELECT
    'Silver Payments',
    COUNT(*),
    SUM(payment_value),
    NULL
FROM silver.order_payments

UNION ALL

SELECT
    'Gold FactPayments',
    COUNT(*),
    SUM(payment_value),
    NULL
FROM gold.FactPayments;
GO


/* =========================================================
   3. DELIVERY CONTROL TOTALS
   ========================================================= */

SELECT
    'Silver Delivery' AS source_table,
    COUNT(*) AS row_count,
    SUM(delivery_days) AS total_delivery_days,
    SUM(delivery_delay_days) AS total_delay_days
FROM silver.delivery

UNION ALL

SELECT
    'Gold FactDelivery',
    COUNT(*),
    SUM(delivery_days),
    SUM(delivery_delay_days)
FROM gold.FactDelivery;
GO


/* =========================================================
   4. FOREIGN KEY INTEGRITY
   Expected Result: All invalid_rows = 0
   ========================================================= */

SELECT
    'FactSales - Customer' AS check_name,
    COUNT(*) AS invalid_rows
FROM gold.FactSales f
LEFT JOIN gold.DimCustomer d
    ON f.customer_key = d.customer_key
WHERE d.customer_key IS NULL

UNION ALL

SELECT
    'FactSales - Product',
    COUNT(*)
FROM gold.FactSales f
LEFT JOIN gold.DimProduct d
    ON f.product_key = d.product_key
WHERE d.product_key IS NULL

UNION ALL

SELECT
    'FactSales - Seller',
    COUNT(*)
FROM gold.FactSales f
LEFT JOIN gold.DimSeller d
    ON f.seller_key = d.seller_key
WHERE d.seller_key IS NULL

UNION ALL

SELECT
    'FactSales - Date',
    COUNT(*)
FROM gold.FactSales f
LEFT JOIN gold.DimDate d
    ON f.order_date_key = d.date_key
WHERE d.date_key IS NULL

UNION ALL

SELECT
    'FactPayments - Customer',
    COUNT(*)
FROM gold.FactPayments f
LEFT JOIN gold.DimCustomer d
    ON f.customer_key = d.customer_key
WHERE d.customer_key IS NULL

UNION ALL

SELECT
    'FactPayments - Date',
    COUNT(*)
FROM gold.FactPayments f
LEFT JOIN gold.DimDate d
    ON f.order_date_key = d.date_key
WHERE d.date_key IS NULL

UNION ALL

SELECT
    'FactDelivery - Customer',
    COUNT(*)
FROM gold.FactDelivery f
LEFT JOIN gold.DimCustomer d
    ON f.customer_key = d.customer_key
WHERE d.customer_key IS NULL

UNION ALL

SELECT
    'FactDelivery - Delivered Date',
    COUNT(*)
FROM gold.FactDelivery f
LEFT JOIN gold.DimDate d
    ON f.delivered_date_key = d.date_key
WHERE f.delivered_date_key IS NOT NULL
  AND d.date_key IS NULL

UNION ALL

SELECT
    'FactDelivery - Carrier Date',
    COUNT(*)
FROM gold.FactDelivery f
LEFT JOIN gold.DimDate d
    ON f.carrier_date_key = d.date_key
WHERE f.carrier_date_key IS NOT NULL
  AND d.date_key IS NULL

UNION ALL

SELECT
    'FactDelivery - Estimated Date',
    COUNT(*)
FROM gold.FactDelivery f
LEFT JOIN gold.DimDate d
    ON f.estimated_delivery_date_key = d.date_key
WHERE f.estimated_delivery_date_key IS NOT NULL
  AND d.date_key IS NULL;
GO


/* =========================================================
   5. FACT GRAIN VALIDATION
   Expected:
   total_rows = distinct_grain
   ========================================================= */

SELECT
    'FactSales' AS fact_table,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT CONCAT(order_id, '|', order_item_id)) AS distinct_grain
FROM gold.FactSales

UNION ALL

SELECT
    'FactPayments',
    COUNT(*),
    COUNT(DISTINCT CONCAT(order_id, '|', payment_sequential))
FROM gold.FactPayments

UNION ALL

SELECT
    'FactDelivery',
    COUNT(*),
    COUNT(DISTINCT order_id)
FROM gold.FactDelivery;
GO


/* =========================================================
   6. DIMENSION UNIQUENESS VALIDATION
   Expected: duplicate_count = 0
   ========================================================= */

SELECT
    'DimCustomer' AS dimension_name,
    COUNT(*) - COUNT(DISTINCT customer_unique_id) AS duplicate_count
FROM gold.DimCustomer

UNION ALL

SELECT
    'DimProduct',
    COUNT(*) - COUNT(DISTINCT product_id)
FROM gold.DimProduct

UNION ALL

SELECT
    'DimSeller',
    COUNT(*) - COUNT(DISTINCT seller_id)
FROM gold.DimSeller;
GO


/* =========================================================
   7. SILVER DATA QUALITY SUMMARY
   ========================================================= */

SELECT
    'Orders' AS table_name,
    data_quality_status,
    COUNT(*) AS row_count
FROM silver.orders
GROUP BY data_quality_status

UNION ALL

SELECT
    'Order Items',
    data_quality_status,
    COUNT(*)
FROM silver.order_items
GROUP BY data_quality_status

UNION ALL

SELECT
    'Products',
    data_quality_status,
    COUNT(*)
FROM silver.products
GROUP BY data_quality_status

UNION ALL

SELECT
    'Customers',
    data_quality_status,
    COUNT(*)
FROM silver.customers
GROUP BY data_quality_status

UNION ALL

SELECT
    'Sellers',
    data_quality_status,
    COUNT(*)
FROM silver.sellers
GROUP BY data_quality_status

UNION ALL

SELECT
    'Payments',
    data_quality_status,
    COUNT(*)
FROM silver.order_payments
GROUP BY data_quality_status

UNION ALL

SELECT
    'Delivery',
    data_quality_status,
    COUNT(*)
FROM silver.delivery
GROUP BY data_quality_status;
GO
