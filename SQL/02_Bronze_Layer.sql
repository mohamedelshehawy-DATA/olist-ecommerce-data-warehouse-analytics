USE EcommerceDW;
GO

/* =========================================
   BRONZE LAYER
   Raw source data
   ========================================= */


/* =========================
   Orders
   ========================= */

CREATE TABLE bronze.orders
(
    order_id VARCHAR(50),
    customer_id VARCHAR(50),
    order_status VARCHAR(30),
    order_purchase_timestamp VARCHAR(50),
    order_approved_at VARCHAR(50),
    order_delivered_carrier_date VARCHAR(50),
    order_delivered_customer_date VARCHAR(50),
    order_estimated_delivery_date VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Order Items
   ========================= */

CREATE TABLE bronze.order_items
(
    order_id VARCHAR(50),
    order_item_id VARCHAR(50),
    product_id VARCHAR(50),
    seller_id VARCHAR(50),
    shipping_limit_date VARCHAR(50),
    price VARCHAR(50),
    freight_value VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Products
   ========================= */

CREATE TABLE bronze.products
(
    product_id VARCHAR(50),
    product_category_name VARCHAR(255),
    product_name_lenght VARCHAR(50),
    product_description_lenght VARCHAR(50),
    product_photos_qty VARCHAR(50),
    product_weight_g VARCHAR(50),
    product_length_cm VARCHAR(50),
    product_height_cm VARCHAR(50),
    product_width_cm VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Customers
   ========================= */

CREATE TABLE bronze.customers
(
    customer_id VARCHAR(50),
    customer_unique_id VARCHAR(50),
    customer_zip_code_prefix VARCHAR(50),
    customer_city VARCHAR(100),
    customer_state VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Sellers
   ========================= */

CREATE TABLE bronze.sellers
(
    seller_id VARCHAR(50),
    seller_zip_code_prefix VARCHAR(50),
    seller_city VARCHAR(100),
    seller_state VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Order Payments
   ========================= */

CREATE TABLE bronze.order_payments
(
    order_id VARCHAR(50),
    payment_sequential VARCHAR(50),
    payment_type VARCHAR(50),
    payment_installments VARCHAR(50),
    payment_value VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Order Reviews
   ========================= */

CREATE TABLE bronze.order_reviews
(
    review_id VARCHAR(50),
    order_id VARCHAR(50),
    review_score VARCHAR(50),
    review_comment_title VARCHAR(MAX),
    review_comment_message VARCHAR(MAX),
    review_creation_date VARCHAR(50),
    review_answer_timestamp VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Geolocation
   ========================= */

CREATE TABLE bronze.geolocation
(
    geolocation_zip_code_prefix VARCHAR(50),
    geolocation_lat VARCHAR(50),
    geolocation_lng VARCHAR(50),
    geolocation_city VARCHAR(100),
    geolocation_state VARCHAR(50),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO


/* =========================
   Category Translation
   ========================= */

CREATE TABLE bronze.category_translation
(
    product_category_name VARCHAR(255),
    product_category_name_english VARCHAR(255),

    load_id BIGINT,
    load_datetime DATETIME2,
    source_file VARCHAR(255)
);
GO
