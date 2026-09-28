USE EcommerceDW;
GO

/* =========================================
   GOLD LAYER
   Analytical Star Schema
   ========================================= */


/* =========================
   Dimension: Date
   ========================= */

CREATE TABLE gold.DimDate
(
    date_key INT NOT NULL,
    full_date DATE NOT NULL,
    year INT NOT NULL,
    quarter INT NOT NULL,
    month INT NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    week_of_year INT NOT NULL,
    day_of_month INT NOT NULL,
    day_of_week INT NOT NULL,
    day_name VARCHAR(20) NOT NULL,

    CONSTRAINT PK_DimDate
        PRIMARY KEY (date_key)
);
GO


/* =========================
   Dimension: Customer
   ========================= */

CREATE TABLE gold.DimCustomer
(
    customer_key INT IDENTITY(1,1) NOT NULL,
    customer_unique_id VARCHAR(50) NOT NULL,
    customer_id VARCHAR(50) NOT NULL,
    customer_zip_code_prefix VARCHAR(5) NULL,
    customer_city VARCHAR(100) NULL,
    customer_state VARCHAR(2) NULL,

    CONSTRAINT PK_DimCustomer
        PRIMARY KEY (customer_key),

    CONSTRAINT UQ_DimCustomer_CustomerUnique
        UNIQUE (customer_unique_id)
);
GO


/* =========================
   Dimension: Product
   ========================= */

CREATE TABLE gold.DimProduct
(
    product_key INT IDENTITY(1,1) NOT NULL,
    product_id VARCHAR(50) NOT NULL,
    product_category_name VARCHAR(255) NULL,
    product_category_name_english VARCHAR(255) NULL,

    product_name_length INT NULL,
    product_description_length INT NULL,
    product_photos_qty INT NULL,

    product_weight_g DECIMAL(18,2) NULL,
    product_length_cm DECIMAL(18,2) NULL,
    product_height_cm DECIMAL(18,2) NULL,
    product_width_cm DECIMAL(18,2) NULL,

    CONSTRAINT PK_DimProduct
        PRIMARY KEY (product_key),

    CONSTRAINT UQ_DimProduct_Product
        UNIQUE (product_id)
);
GO


/* =========================
   Dimension: Seller
   ========================= */

CREATE TABLE gold.DimSeller
(
    seller_key INT IDENTITY(1,1) NOT NULL,
    seller_id VARCHAR(50) NOT NULL,
    seller_zip_code_prefix VARCHAR(5) NULL,
    seller_city VARCHAR(100) NULL,
    seller_state VARCHAR(2) NULL,

    CONSTRAINT PK_DimSeller
        PRIMARY KEY (seller_key),

    CONSTRAINT UQ_DimSeller_Seller
        UNIQUE (seller_id)
);
GO


/* =========================
   Fact: Sales
   Grain:
   One product line within one order
   ========================= */

CREATE TABLE gold.FactSales
(
    sales_key BIGINT IDENTITY(1,1) NOT NULL,

    order_id VARCHAR(50) NOT NULL,
    order_item_id INT NOT NULL,

    customer_key INT NOT NULL,
    product_key INT NOT NULL,
    seller_key INT NOT NULL,
    order_date_key INT NOT NULL,

    price DECIMAL(18,2) NULL,
    freight_value DECIMAL(18,2) NULL,

    CONSTRAINT PK_FactSales
        PRIMARY KEY (sales_key),

    CONSTRAINT UQ_FactSales_OrderItem
        UNIQUE (order_id, order_item_id),

    CONSTRAINT FK_FactSales_Customer
        FOREIGN KEY (customer_key)
        REFERENCES gold.DimCustomer(customer_key),

    CONSTRAINT FK_FactSales_Product
        FOREIGN KEY (product_key)
        REFERENCES gold.DimProduct(product_key),

    CONSTRAINT FK_FactSales_Seller
        FOREIGN KEY (seller_key)
        REFERENCES gold.DimSeller(seller_key),

    CONSTRAINT FK_FactSales_OrderDate
        FOREIGN KEY (order_date_key)
        REFERENCES gold.DimDate(date_key)
);
GO


/* =========================
   Fact: Payments
   Grain:
   One payment record within one order
   ========================= */

CREATE TABLE gold.FactPayments
(
    payment_key BIGINT IDENTITY(1,1) NOT NULL,

    order_id VARCHAR(50) NOT NULL,
    payment_sequential INT NOT NULL,

    customer_key INT NOT NULL,
    order_date_key INT NOT NULL,

    payment_type VARCHAR(50) NULL,
    payment_installments INT NULL,
    payment_value DECIMAL(18,2) NULL,

    CONSTRAINT PK_FactPayments
        PRIMARY KEY (payment_key),

    CONSTRAINT UQ_FactPayments_OrderPayment
        UNIQUE (order_id, payment_sequential),

    CONSTRAINT FK_FactPayments_Customer
        FOREIGN KEY (customer_key)
        REFERENCES gold.DimCustomer(customer_key),

    CONSTRAINT FK_FactPayments_OrderDate
        FOREIGN KEY (order_date_key)
        REFERENCES gold.DimDate(date_key)
);
GO


/* =========================
   Fact: Delivery
   Grain:
   One order
   ========================= */

CREATE TABLE gold.FactDelivery
(
    delivery_key BIGINT IDENTITY(1,1) NOT NULL,

    order_id VARCHAR(50) NOT NULL,
    customer_key INT NOT NULL,

    carrier_date_key INT NULL,
    delivered_date_key INT NULL,
    estimated_delivery_date_key INT NULL,

    delivery_days INT NULL,
    delivery_delay_days INT NULL,
    delivery_status VARCHAR(30) NOT NULL,

    CONSTRAINT PK_FactDelivery
        PRIMARY KEY (delivery_key),

    CONSTRAINT UQ_FactDelivery_Order
        UNIQUE (order_id),

    CONSTRAINT FK_FactDelivery_Customer
        FOREIGN KEY (customer_key)
        REFERENCES gold.DimCustomer(customer_key),

    CONSTRAINT FK_FactDelivery_CarrierDate
        FOREIGN KEY (carrier_date_key)
        REFERENCES gold.DimDate(date_key),

    CONSTRAINT FK_FactDelivery_DeliveredDate
        FOREIGN KEY (delivered_date_key)
        REFERENCES gold.DimDate(date_key),

    CONSTRAINT FK_FactDelivery_EstimatedDate
        FOREIGN KEY (estimated_delivery_date_key)
        REFERENCES gold.DimDate(date_key)
);
GO
