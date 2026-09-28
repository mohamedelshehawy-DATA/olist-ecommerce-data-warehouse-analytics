USE EcommerceDW;
GO

/* =========================================
   SILVER LAYER
   Cleaned, standardized and validated data
   ========================================= */


/* =========================
   Orders
   ========================= */

CREATE TABLE silver.orders
(
    order_id VARCHAR(50) NOT NULL,
    customer_id VARCHAR(50) NULL,
    order_status VARCHAR(30) NULL,
    order_purchase_timestamp DATETIME2 NULL,
    order_approved_at DATETIME2 NULL,
    order_delivered_carrier_date DATETIME2 NULL,
    order_delivered_customer_date DATETIME2 NULL,
    order_estimated_delivery_date DATETIME2 NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_Orders
        PRIMARY KEY (order_id)
);
GO


/* =========================
   Order Items
   ========================= */

CREATE TABLE silver.order_items
(
    order_id VARCHAR(50) NOT NULL,
    order_item_id INT NOT NULL,
    product_id VARCHAR(50) NULL,
    seller_id VARCHAR(50) NULL,
    shipping_limit_date DATETIME2 NULL,
    price DECIMAL(18,2) NULL,
    freight_value DECIMAL(18,2) NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_OrderItems
        PRIMARY KEY (order_id, order_item_id)
);
GO


/* =========================
   Products
   ========================= */

CREATE TABLE silver.products
(
    product_id VARCHAR(50) NOT NULL,
    product_category_name VARCHAR(255) NULL,

    product_name_length INT NULL,
    product_description_length INT NULL,
    product_photos_qty INT NULL,

    product_weight_g DECIMAL(18,2) NULL,
    product_length_cm DECIMAL(18,2) NULL,
    product_height_cm DECIMAL(18,2) NULL,
    product_width_cm DECIMAL(18,2) NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_Products
        PRIMARY KEY (product_id)
);
GO


/* =========================
   Customers
   ========================= */

CREATE TABLE silver.customers
(
    customer_id VARCHAR(50) NOT NULL,
    customer_unique_id VARCHAR(50) NOT NULL,
    customer_zip_code_prefix VARCHAR(5) NULL,
    customer_city VARCHAR(100) NULL,
    customer_state VARCHAR(10) NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_Customers
        PRIMARY KEY (customer_id)
);
GO


/* =========================
   Sellers
   ========================= */

CREATE TABLE silver.sellers
(
    seller_id VARCHAR(50) NOT NULL,
    seller_zip_code_prefix VARCHAR(5) NULL,
    seller_city VARCHAR(100) NULL,
    seller_state VARCHAR(2) NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_Sellers
        PRIMARY KEY (seller_id)
);
GO


/* =========================
   Order Payments
   ========================= */

CREATE TABLE silver.order_payments
(
    order_id VARCHAR(50) NOT NULL,
    payment_sequential INT NOT NULL,
    payment_type VARCHAR(50) NULL,
    payment_installments INT NULL,
    payment_value DECIMAL(18,2) NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_OrderPayments
        PRIMARY KEY (order_id, payment_sequential)
);
GO


/* =========================
   Delivery
   Derived from Silver Orders
   ========================= */

CREATE TABLE silver.delivery
(
    order_id VARCHAR(50) NOT NULL,
    customer_id VARCHAR(50) NULL,

    order_purchase_timestamp DATETIME2 NULL,
    order_delivered_carrier_date DATETIME2 NULL,
    order_delivered_customer_date DATETIME2 NULL,
    order_estimated_delivery_date DATETIME2 NULL,

    delivery_days INT NULL,
    delivery_delay_days INT NULL,
    delivery_status VARCHAR(30) NOT NULL,

    data_quality_status VARCHAR(20) NOT NULL,
    data_quality_reason VARCHAR(255) NULL,

    source_load_id BIGINT NOT NULL,
    source_load_datetime DATETIME2 NOT NULL,
    source_file VARCHAR(255) NOT NULL,

    CONSTRAINT PK_Silver_Delivery
        PRIMARY KEY (order_id)
);
GO
