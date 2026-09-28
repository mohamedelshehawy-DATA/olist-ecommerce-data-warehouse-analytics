USE [ EcommerceDW]
GO
/****** Object:  StoredProcedure [etl].[usp_load_bronze_csv]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_bronze_csv]
    @TargetTable SYSNAME,
    @FilePath NVARCHAR(4000),
    @SourceBatchKey VARCHAR(200),
    @SourceFileName VARCHAR(255),
    @RawDefinition NVARCHAR(MAX),
    @Columns NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Bronze_Load',
        @BatchID BIGINT = NULL,
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @ExistingStatus VARCHAR(20),
        @LoadTime DATETIME2 = SYSDATETIME(),
        @SQL NVARCHAR(MAX);

    BEGIN TRY

        --------------------------------------------------
        -- 1. Check target table
        --------------------------------------------------
        IF NOT EXISTS
        (
            SELECT 1
            FROM sys.tables t
            JOIN sys.schemas s
                ON t.schema_id = s.schema_id
            WHERE s.name = 'bronze'
              AND t.name = @TargetTable
        )
        BEGIN
            THROW 50010, 'Target Bronze table does not exist.', 1;
        END;


        --------------------------------------------------
        -- 2. Check Batch
        --------------------------------------------------
        SELECT
            @BatchID = batch_id,
            @ExistingStatus = status
        FROM etl.Batch_Control
        WHERE pipeline_name = @PipelineName
          AND source_batch_key = @SourceBatchKey;


        IF @ExistingStatus = 'Success'
        BEGIN
            THROW 50001,
                'This source batch has already been loaded successfully.',
                1;
        END;


        IF @ExistingStatus = 'Running'
        BEGIN
            THROW 50002,
                'This source batch is already running.',
                1;
        END;


        --------------------------------------------------
        -- 3. Start Run Log
        --------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        --------------------------------------------------
        -- 4. Create or reuse Batch
        --------------------------------------------------
        IF @BatchID IS NULL
        BEGIN
            INSERT INTO etl.Batch_Control
            (
                pipeline_name,
                source_name,
                source_batch_key,
                status
            )
            VALUES
            (
                @PipelineName,
                @SourceFileName,
                @SourceBatchKey,
                'Running'
            );

            SET @BatchID = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE etl.Batch_Control
            SET
                source_name = @SourceFileName,
                batch_start_time = SYSDATETIME(),
                batch_end_time = NULL,
                status = 'Running',
                rows_loaded = NULL
            WHERE batch_id = @BatchID;
        END;


        --------------------------------------------------
        -- 5 → 8
        -- Temp Table + BULK INSERT + Bronze Load
        -- MUST be in the same dynamic SQL scope
        --------------------------------------------------
        SET @SQL = N'
        CREATE TABLE #RawData
        (
            ' + @RawDefinition + N'
        );

        BULK INSERT #RawData
        FROM ''' + REPLACE(@FilePath, '''', '''''') + N'''
        WITH
        (
            DATAFILETYPE = ''char'',
            FIRSTROW = 2,
            FIELDTERMINATOR = '','',
            ROWTERMINATOR = ''0x0a'',
            CODEPAGE = ''65001''
        );

        SELECT @RowsExtractedOut = COUNT(*)
        FROM #RawData;

        IF @RowsExtractedOut = 0
        BEGIN
            THROW 50003,
                ''The source file contains no data.'',
                1;
        END;

        BEGIN TRANSACTION;

        INSERT INTO bronze.' + QUOTENAME(@TargetTable) + N'
        (
            ' + @Columns + N',
            load_id,
            load_datetime,
            source_file
        )
        SELECT
            ' + @Columns + N',
            @BatchID,
            @LoadTime,
            @SourceFileName
        FROM #RawData;

        SET @RowsLoadedOut = @@ROWCOUNT;

        COMMIT TRANSACTION;
        ';


        EXEC sys.sp_executesql
            @SQL,
            N'@BatchID BIGINT,
              @LoadTime DATETIME2,
              @SourceFileName VARCHAR(255),
              @RowsExtractedOut INT OUTPUT,
              @RowsLoadedOut INT OUTPUT',
            @BatchID = @BatchID,
            @LoadTime = @LoadTime,
            @SourceFileName = @SourceFileName,
            @RowsExtractedOut = @RowsExtracted OUTPUT,
            @RowsLoadedOut = @RowsLoaded OUTPUT;


        --------------------------------------------------
        -- 9. Mark Batch Success
        --------------------------------------------------
        UPDATE etl.Batch_Control
        SET
            batch_end_time = SYSDATETIME(),
            status = 'Success',
            rows_loaded = @RowsLoaded
        WHERE batch_id = @BatchID;


        --------------------------------------------------
        -- 10. Mark Run Success
        --------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = 0
        WHERE run_id = @RunID;


        --------------------------------------------------
        -- 11. Return Result
        --------------------------------------------------
        SELECT
            @BatchID AS batch_id,
            @RowsExtracted AS rows_extracted,
            @RowsLoaded AS rows_loaded,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        IF @BatchID IS NOT NULL
        BEGIN
            UPDATE etl.Batch_Control
            SET
                batch_end_time = SYSDATETIME(),
                status = 'Failed',
                rows_loaded = ISNULL(@RowsLoaded, 0)
            WHERE batch_id = @BatchID;
        END;


        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = 0,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_bronze_order_items]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_bronze_order_items]
    @FilePath NVARCHAR(4000),
    @SourceBatchKey VARCHAR(200),
    @SourceFileName VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @BatchID BIGINT = NULL,
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @LoadTime DATETIME2 = SYSDATETIME();

    BEGIN TRY

        --------------------------------------------------
        -- 1. Idempotency Check
        --------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Batch_Control
            WHERE pipeline_name = 'Olist_Bronze_Load'
              AND source_batch_key = @SourceBatchKey
              AND status = 'Success'
        )
        BEGIN
            THROW 50001,
                  'This source batch has already been loaded successfully.',
                  1;
        END;


        --------------------------------------------------
        -- 2. Start Run Log
        --------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            'Olist_Bronze_OrderItems',
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        --------------------------------------------------
        -- 3. Create Batch Record
        --------------------------------------------------
        INSERT INTO etl.Batch_Control
        (
            pipeline_name,
            source_name,
            source_batch_key,
            status
        )
        VALUES
        (
            'Olist_Bronze_Load',
            @SourceFileName,
            @SourceBatchKey,
            'Running'
        );

        SET @BatchID = SCOPE_IDENTITY();


        --------------------------------------------------
        -- 4. Temporary Raw Table
        --------------------------------------------------
        CREATE TABLE #br_order_items_raw
        (
            order_id VARCHAR(50),
            order_item_id VARCHAR(50),
            product_id VARCHAR(50),
            seller_id VARCHAR(50),
            shipping_limit_date VARCHAR(50),
            price VARCHAR(50),
            freight_value VARCHAR(50)
        );


        --------------------------------------------------
        -- 5. Load CSV
        --------------------------------------------------
        DECLARE @SQL NVARCHAR(MAX);

        SET @SQL = N'
        BULK INSERT #br_order_items_raw
        FROM ''' + REPLACE(@FilePath, '''', '''''') + N'''
        WITH
        (
            DATAFILETYPE = ''char'',
            FIRSTROW = 2,
            FIELDTERMINATOR = '','',
            ROWTERMINATOR = ''0x0a'',
            CODEPAGE = ''65001''
        );';

        EXEC sys.sp_executesql @SQL;


        --------------------------------------------------
        -- 6. Count Extracted Rows
        --------------------------------------------------
        SELECT @RowsExtracted = COUNT(*)
        FROM #br_order_items_raw;

        IF @RowsExtracted = 0
        BEGIN
            THROW 50002,
                  'The source file contains no data.',
                  1;
        END;


        --------------------------------------------------
        -- 7. Load Bronze
        --------------------------------------------------
        BEGIN TRANSACTION;

        INSERT INTO bronze.order_items
        (
            order_id,
            order_item_id,
            product_id,
            seller_id,
            shipping_limit_date,
            price,
            freight_value,
            load_id,
            load_datetime,
            source_file
        )
        SELECT
            order_id,
            order_item_id,
            product_id,
            seller_id,
            shipping_limit_date,
            price,
            freight_value,
            @BatchID,
            @LoadTime,
            @SourceFileName
        FROM #br_order_items_raw;

        SET @RowsLoaded = @@ROWCOUNT;

        COMMIT TRANSACTION;


        --------------------------------------------------
        -- 8. Mark Batch Successful
        --------------------------------------------------
        UPDATE etl.Batch_Control
        SET
            batch_end_time = SYSDATETIME(),
            status = 'Success',
            rows_loaded = @RowsLoaded
        WHERE batch_id = @BatchID;


        --------------------------------------------------
        -- 9. Mark Run Successful
        --------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = 0
        WHERE run_id = @RunID;

    END TRY

    BEGIN CATCH

        --------------------------------------------------
        -- Rollback if needed
        --------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        --------------------------------------------------
        -- Mark Batch Failed
        --------------------------------------------------
        IF @BatchID IS NOT NULL
        BEGIN
            UPDATE etl.Batch_Control
            SET
                batch_end_time = SYSDATETIME(),
                status = 'Failed',
                rows_loaded = ISNULL(@RowsLoaded, 0)
            WHERE batch_id = @BatchID;
        END;


        --------------------------------------------------
        -- Mark Run Failed
        --------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = 0,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;


        THROW;

    END CATCH;
END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_bronze_orders]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_bronze_orders]
    @FilePath NVARCHAR(4000),
    @SourceBatchKey VARCHAR(200),
    @SourceFileName VARCHAR(255)
AS
BEGIN

    SET NOCOUNT ON;

    DECLARE
        @BatchID BIGINT = NULL,
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @LoadTime DATETIME2 = SYSDATETIME();

    BEGIN TRY

        --------------------------------------------------
        -- 1. Prevent the same batch from loading twice
        --------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Batch_Control
            WHERE pipeline_name = 'Olist_Bronze_Load'
              AND source_batch_key = @SourceBatchKey
              AND status = 'Success'
        )
        BEGIN
            THROW 50001, 'This source batch has already been loaded successfully.', 1;
        END;


        --------------------------------------------------
        -- 2. Start Run Log
        --------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            'Olist_Bronze_Load',
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        --------------------------------------------------
        -- 3. Create Batch
        --------------------------------------------------
        INSERT INTO etl.Batch_Control
        (
            pipeline_name,
            source_name,
            source_batch_key,
            status
        )
        VALUES
        (
            'Olist_Bronze_Load',
            @SourceFileName,
            @SourceBatchKey,
            'Running'
        );

        SET @BatchID = SCOPE_IDENTITY();


        --------------------------------------------------
        -- 4. Temporary Raw Table
        --------------------------------------------------
        CREATE TABLE #orders_raw
        (
            order_id VARCHAR(50),
            customer_id VARCHAR(50),
            order_status VARCHAR(30),
            order_purchase_timestamp VARCHAR(50),
            order_approved_at VARCHAR(50),
            order_delivered_carrier_date VARCHAR(50),
            order_delivered_customer_date VARCHAR(50),
            order_estimated_delivery_date VARCHAR(50)
        );


        --------------------------------------------------
        -- 5. Load CSV into Temporary Table
        --------------------------------------------------
        DECLARE @SQL NVARCHAR(MAX);

        SET @SQL = N'
        BULK INSERT #orders_raw
        FROM ''' + REPLACE(@FilePath, '''', '''''') + N'''
        WITH
        (
            DATAFILETYPE = ''char'',
            FIRSTROW = 2,
            FIELDTERMINATOR = '','',
            ROWTERMINATOR = ''0x0a'',
            CODEPAGE = ''65001''
        );';

        EXEC sys.sp_executesql @SQL;


        --------------------------------------------------
        -- 6. Count Extracted Rows
        --------------------------------------------------
        SELECT @RowsExtracted = COUNT(*)
        FROM #orders_raw;


        IF @RowsExtracted = 0
        BEGIN
            THROW 50002, 'The source file contains no data.', 1;
        END;


        --------------------------------------------------
        -- 7. Load Bronze
        --------------------------------------------------
        BEGIN TRANSACTION;

        INSERT INTO bronze.orders
        (
            order_id,
            customer_id,
            order_status,
            order_purchase_timestamp,
            order_approved_at,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,
            load_id,
            load_datetime,
            source_file
        )
        SELECT
            order_id,
            customer_id,
            order_status,
            order_purchase_timestamp,
            order_approved_at,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,
            @BatchID,
            @LoadTime,
            @SourceFileName
        FROM #orders_raw;

        SET @RowsLoaded = @@ROWCOUNT;

        COMMIT TRANSACTION;


        --------------------------------------------------
        -- 8. Mark Batch as Successful
        --------------------------------------------------
        UPDATE etl.Batch_Control
        SET
            batch_end_time = SYSDATETIME(),
            status = 'Success',
            rows_loaded = @RowsLoaded
        WHERE batch_id = @BatchID;


        --------------------------------------------------
        -- 9. Mark Run as Successful
        --------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = 0
        WHERE run_id = @RunID;


    END TRY

    BEGIN CATCH

        --------------------------------------------------
        -- Rollback Bronze if transaction is still open
        --------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        --------------------------------------------------
        -- Log Failure
        --------------------------------------------------
        IF @BatchID IS NOT NULL
        BEGIN
            UPDATE etl.Batch_Control
            SET
                batch_end_time = SYSDATETIME(),
                status = 'Failed',
                rows_loaded = ISNULL(@RowsLoaded, 0)
            WHERE batch_id = @BatchID;
        END;


        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = 0,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_gold_dim_customer]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_gold_dim_customer]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Gold_DimCustomer',
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Build Customer Source
        --
        -- One row per customer_unique_id
        -- Choose the customer record associated with
        -- the latest purchase.
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CustomerSource;

        ;WITH CustomerWithLatestOrder AS
        (
            SELECT

                c.customer_unique_id,
                c.customer_id,

                c.customer_zip_code_prefix,
                c.customer_city,
                c.customer_state,

                c.source_load_id,
                c.source_load_datetime,
                c.source_file,

                o.order_purchase_timestamp,

                ROW_NUMBER() OVER
                (
                    PARTITION BY c.customer_unique_id
                    ORDER BY
                        o.order_purchase_timestamp DESC,
                        c.source_load_datetime DESC,
                        c.source_load_id DESC
                ) AS rn

            FROM silver.customers c

            LEFT JOIN silver.orders o
                ON c.customer_id = o.customer_id
        )

        SELECT

            customer_unique_id,
            customer_id,

            customer_zip_code_prefix,
            customer_city,
            customer_state,

            source_load_id,
            source_load_datetime,
            source_file

        INTO #CustomerSource

        FROM CustomerWithLatestOrder

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 4. Count Source Rows
        ----------------------------------------------------------------
        SELECT
            @RowsExtracted = COUNT(*)
        FROM #CustomerSource;


        ----------------------------------------------------------------
        -- 5. Basic Validation
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM #CustomerSource
            WHERE customer_unique_id IS NULL
        )
        BEGIN
            SET @RowsRejected =
            (
                SELECT COUNT(*)
                FROM #CustomerSource
                WHERE customer_unique_id IS NULL
            );

            THROW 50020,
                'Invalid DimCustomer source: customer_unique_id is NULL.',
                1;
        END;


        ----------------------------------------------------------------
        -- 6. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 7. Update Existing Customers
        ----------------------------------------------------------------
        UPDATE d
        SET

            customer_id =
                s.customer_id,

            customer_zip_code_prefix =
                s.customer_zip_code_prefix,

            customer_city =
                s.customer_city,

            customer_state =
                s.customer_state

        FROM gold.DimCustomer d

        INNER JOIN #CustomerSource s
            ON d.customer_unique_id =
               s.customer_unique_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 8. Insert New Customers
        ----------------------------------------------------------------
        INSERT INTO gold.DimCustomer
        (
            customer_unique_id,
            customer_id,

            customer_zip_code_prefix,
            customer_city,
            customer_state
        )

        SELECT

            s.customer_unique_id,
            s.customer_id,

            s.customer_zip_code_prefix,
            s.customer_city,
            s.customer_state

        FROM #CustomerSource s

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gold.DimCustomer d
            WHERE d.customer_unique_id =
                  s.customer_unique_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 9. Total Loaded
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 10. Commit
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 11. Update Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 12. Return Result
        ----------------------------------------------------------------
        SELECT

            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_gold_dim_product]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_gold_dim_product]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Gold_DimProduct',
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0;

    BEGIN TRY

        -- 1. Start logging
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        -- 2. Prepare source data
        DROP TABLE IF EXISTS #ProductSource;

        ;WITH CategoryTranslation AS
        (
            SELECT
                product_category_name,
                MAX(product_category_name_english) AS product_category_name_english
            FROM bronze.category_translation
            GROUP BY product_category_name
        )
        SELECT
            p.product_id,
            p.product_category_name,
            ct.product_category_name_english,
            p.product_name_length,
            p.product_description_length,
            p.product_photos_qty,
            p.product_weight_g,
            p.product_length_cm,
            p.product_height_cm,
            p.product_width_cm
        INTO #ProductSource
        FROM silver.products p
        LEFT JOIN CategoryTranslation ct
            ON p.product_category_name = ct.product_category_name
        WHERE p.data_quality_status <> 'REJECTED';


        -- 3. Count extracted rows
        SELECT
            @RowsExtracted = COUNT(*)
        FROM #ProductSource;


        -- 4. Validate product_id
        IF EXISTS
        (
            SELECT 1
            FROM #ProductSource
            WHERE product_id IS NULL
        )
        BEGIN
            SET @RowsRejected =
            (
                SELECT COUNT(*)
                FROM #ProductSource
                WHERE product_id IS NULL
            );

            THROW 50021,
                'Invalid DimProduct source: product_id is NULL.',
                1;
        END;


        BEGIN TRANSACTION;


        -- 5. Update existing products
        UPDATE d
        SET
            product_category_name = s.product_category_name,
            product_category_name_english = s.product_category_name_english,
            product_name_length = s.product_name_length,
            product_description_length = s.product_description_length,
            product_photos_qty = s.product_photos_qty,
            product_weight_g = s.product_weight_g,
            product_length_cm = s.product_length_cm,
            product_height_cm = s.product_height_cm,
            product_width_cm = s.product_width_cm
        FROM gold.DimProduct d
        INNER JOIN #ProductSource s
            ON d.product_id = s.product_id;


        SET @RowsUpdated = @@ROWCOUNT;


        -- 6. Insert new products
        INSERT INTO gold.DimProduct
        (
            product_id,
            product_category_name,
            product_category_name_english,
            product_name_length,
            product_description_length,
            product_photos_qty,
            product_weight_g,
            product_length_cm,
            product_height_cm,
            product_width_cm
        )
        SELECT
            s.product_id,
            s.product_category_name,
            s.product_category_name_english,
            s.product_name_length,
            s.product_description_length,
            s.product_photos_qty,
            s.product_weight_g,
            s.product_length_cm,
            s.product_height_cm,
            s.product_width_cm
        FROM #ProductSource s
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gold.DimProduct d
            WHERE d.product_id = s.product_id
        );


        SET @RowsInserted = @@ROWCOUNT;

        SET @RowsLoaded = @RowsUpdated + @RowsInserted;


        COMMIT TRANSACTION;


        -- 7. Finish logging
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        -- 8. Return result
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsRejected AS rows_rejected,
            'Success' AS status;

    END TRY

    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;

        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_gold_dim_seller]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_gold_dim_seller]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Gold_DimSeller',
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0;

    BEGIN TRY

        -- 1. Start logging
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        -- 2. Prepare source data
        DROP TABLE IF EXISTS #SellerSource;

        SELECT
            seller_id,
            seller_zip_code_prefix,
            seller_city,
            seller_state
        INTO #SellerSource
        FROM silver.sellers
        WHERE data_quality_status <> 'REJECTED';


        -- 3. Count extracted rows
        SELECT
            @RowsExtracted = COUNT(*)
        FROM #SellerSource;


        -- 4. Validate seller_id
        IF EXISTS
        (
            SELECT 1
            FROM #SellerSource
            WHERE seller_id IS NULL
        )
        BEGIN
            SET @RowsRejected =
            (
                SELECT COUNT(*)
                FROM #SellerSource
                WHERE seller_id IS NULL
            );

            THROW 50022,
                'Invalid DimSeller source: seller_id is NULL.',
                1;
        END;


        BEGIN TRANSACTION;


        -- 5. Update existing sellers
        UPDATE d
        SET
            seller_zip_code_prefix = s.seller_zip_code_prefix,
            seller_city = s.seller_city,
            seller_state = s.seller_state
        FROM gold.DimSeller d
        INNER JOIN #SellerSource s
            ON d.seller_id = s.seller_id;


        SET @RowsUpdated = @@ROWCOUNT;


        -- 6. Insert new sellers
        INSERT INTO gold.DimSeller
        (
            seller_id,
            seller_zip_code_prefix,
            seller_city,
            seller_state
        )
        SELECT
            s.seller_id,
            s.seller_zip_code_prefix,
            s.seller_city,
            s.seller_state
        FROM #SellerSource s
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gold.DimSeller d
            WHERE d.seller_id = s.seller_id
        );


        SET @RowsInserted = @@ROWCOUNT;

        SET @RowsLoaded = @RowsUpdated + @RowsInserted;


        COMMIT TRANSACTION;


        -- 7. Finish logging
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        -- 8. Return result
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsRejected AS rows_rejected,
            'Success' AS status;

    END TRY

    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;

        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_gold_fact_delivery]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_gold_fact_delivery]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Gold_FactDelivery',
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0;

    BEGIN TRY

        -- 1. Start logging
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        -- 2. Prepare source data
        DROP TABLE IF EXISTS #FactDeliverySource;

        SELECT
            d.order_id,
            dc.customer_key,

            CASE
                WHEN d.order_purchase_timestamp IS NOT NULL
                THEN
                    YEAR(d.order_purchase_timestamp) * 10000
                    + MONTH(d.order_purchase_timestamp) * 100
                    + DAY(d.order_purchase_timestamp)
            END AS purchase_date_key,

            CASE
                WHEN d.order_delivered_carrier_date IS NOT NULL
                THEN
                    YEAR(d.order_delivered_carrier_date) * 10000
                    + MONTH(d.order_delivered_carrier_date) * 100
                    + DAY(d.order_delivered_carrier_date)
            END AS carrier_date_key,

            CASE
                WHEN d.order_delivered_customer_date IS NOT NULL
                THEN
                    YEAR(d.order_delivered_customer_date) * 10000
                    + MONTH(d.order_delivered_customer_date) * 100
                    + DAY(d.order_delivered_customer_date)
            END AS delivered_date_key,

            CASE
                WHEN d.order_estimated_delivery_date IS NOT NULL
                THEN
                    YEAR(d.order_estimated_delivery_date) * 10000
                    + MONTH(d.order_estimated_delivery_date) * 100
                    + DAY(d.order_estimated_delivery_date)
            END AS estimated_delivery_date_key,

            d.delivery_days,
            d.delivery_delay_days,
            d.delivery_status

        INTO #FactDeliverySource

        FROM silver.delivery d

        INNER JOIN silver.customers c
            ON d.customer_id = c.customer_id

        INNER JOIN gold.DimCustomer dc
            ON c.customer_unique_id = dc.customer_unique_id;


        -- 3. Count extracted rows
        SELECT
            @RowsExtracted = COUNT(*)
        FROM #FactDeliverySource;


        -- 4. Validate source
        IF @RowsExtracted = 0
        BEGIN
            SET @RowsRejected =
            (
                SELECT COUNT(*)
                FROM silver.delivery
            );

            THROW 50025,
                'FactDelivery source returned zero rows. Check customer joins.',
                1;
        END;


        BEGIN TRANSACTION;


        -- 5. Insert new delivery records
        INSERT INTO gold.FactDelivery
        (
            order_id,
            customer_key,
            purchase_date_key,
            carrier_date_key,
            delivered_date_key,
            estimated_delivery_date_key,
            delivery_days,
            delivery_delay_days,
            delivery_status
        )
        SELECT
            s.order_id,
            s.customer_key,
            s.purchase_date_key,
            s.carrier_date_key,
            s.delivered_date_key,
            s.estimated_delivery_date_key,
            s.delivery_days,
            s.delivery_delay_days,
            s.delivery_status

        FROM #FactDeliverySource s

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gold.FactDelivery f
            WHERE f.order_id = s.order_id
        );


        SET @RowsInserted = @@ROWCOUNT;

        SET @RowsLoaded = @RowsInserted;


        COMMIT TRANSACTION;


        -- 6. Finish logging
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        -- 7. Return result
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsRejected AS rows_rejected,
            'Success' AS status;

    END TRY

    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;

        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_gold_fact_payments]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_gold_fact_payments]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Gold_FactPayments',
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0;

    BEGIN TRY

        -- 1. Start logging
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        -- 2. Prepare source data
        DROP TABLE IF EXISTS #FactPaymentsSource;

        SELECT
            p.order_id,
            p.payment_sequential,

            dc.customer_key,

            (
                YEAR(o.order_purchase_timestamp) * 10000
                + MONTH(o.order_purchase_timestamp) * 100
                + DAY(o.order_purchase_timestamp)
            ) AS order_date_key,

            p.payment_type,
            p.payment_installments,
            p.payment_value

        INTO #FactPaymentsSource

        FROM silver.order_payments p

        INNER JOIN silver.orders o
            ON p.order_id = o.order_id

        INNER JOIN silver.customers c
            ON o.customer_id = c.customer_id

        INNER JOIN gold.DimCustomer dc
            ON c.customer_unique_id = dc.customer_unique_id;


        -- 3. Count extracted rows
        SELECT
            @RowsExtracted = COUNT(*)
        FROM #FactPaymentsSource;


        -- 4. Validate source
        IF @RowsExtracted = 0
        BEGIN
            SET @RowsRejected =
            (
                SELECT COUNT(*)
                FROM silver.order_payments
            );

            THROW 50024,
                'FactPayments source returned zero rows. Check order and customer joins.',
                1;
        END;


        BEGIN TRANSACTION;


        -- 5. Insert new payment records
        INSERT INTO gold.FactPayments
        (
            order_id,
            payment_sequential,
            customer_key,
            order_date_key,
            payment_type,
            payment_installments,
            payment_value
        )
        SELECT
            s.order_id,
            s.payment_sequential,
            s.customer_key,
            s.order_date_key,
            s.payment_type,
            s.payment_installments,
            s.payment_value
        FROM #FactPaymentsSource s

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gold.FactPayments f
            WHERE f.order_id = s.order_id
              AND f.payment_sequential = s.payment_sequential
        );


        SET @RowsInserted = @@ROWCOUNT;

        SET @RowsLoaded = @RowsInserted;


        COMMIT TRANSACTION;


        -- 6. Finish logging
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        -- 7. Return result
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsRejected AS rows_rejected,
            'Success' AS status;

    END TRY

    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;

        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_gold_fact_sales]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_gold_fact_sales]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Gold_FactSales',
        @RunID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0;

    BEGIN TRY

        -- 1. Start logging
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        -- 2. Prepare FactSales source
        DROP TABLE IF EXISTS #FactSalesSource;

        SELECT
            oi.order_id,
            oi.order_item_id,

            dc.customer_key,
            dp.product_key,
            ds.seller_key,

            (
                YEAR(o.order_purchase_timestamp) * 10000
                + MONTH(o.order_purchase_timestamp) * 100
                + DAY(o.order_purchase_timestamp)
            ) AS order_date_key,

            oi.price,
            oi.freight_value

        INTO #FactSalesSource

        FROM silver.order_items oi

        INNER JOIN silver.orders o
            ON oi.order_id = o.order_id

        INNER JOIN silver.customers c
            ON o.customer_id = c.customer_id

        INNER JOIN gold.DimCustomer dc
            ON c.customer_unique_id = dc.customer_unique_id

        INNER JOIN gold.DimProduct dp
            ON oi.product_id = dp.product_id

        INNER JOIN gold.DimSeller ds
            ON oi.seller_id = ds.seller_id;


        -- 3. Count extracted rows
        SELECT
            @RowsExtracted = COUNT(*)
        FROM #FactSalesSource;


        -- 4. Check for missing records caused by joins
        IF @RowsExtracted = 0
        BEGIN
            SET @RowsRejected =
            (
                SELECT COUNT(*)
                FROM silver.order_items
            );

            THROW 50023,
                'FactSales source returned zero rows. Check dimension and order joins.',
                1;
        END;


        BEGIN TRANSACTION;


        -- 5. Insert new FactSales rows
        INSERT INTO gold.FactSales
        (
            order_id,
            order_item_id,
            customer_key,
            product_key,
            seller_key,
            order_date_key,
            price,
            freight_value
        )
        SELECT
            s.order_id,
            s.order_item_id,
            s.customer_key,
            s.product_key,
            s.seller_key,
            s.order_date_key,
            s.price,
            s.freight_value
        FROM #FactSalesSource s

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gold.FactSales f
            WHERE f.order_id = s.order_id
              AND f.order_item_id = s.order_item_id
        );


        SET @RowsInserted = @@ROWCOUNT;

        SET @RowsLoaded = @RowsInserted;


        COMMIT TRANSACTION;


        -- 6. Finish logging
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        -- 7. Return result
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsRejected AS rows_rejected,
            'Success' AS status;

    END TRY

    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF @RunID IS NOT NULL
        BEGIN
            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;
        END;

        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_customers]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_silver_customers]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_Customers',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New Bronze Data
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(load_id),
            @RowsExtracted = COUNT(*)
        FROM bronze.customers
        WHERE load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. No New Data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;


            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;


            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Clean + Transform + Deduplicate
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanCustomers;


        ;WITH RawCustomers AS
        (
            SELECT

                --------------------------------------------------------
                -- Clean Customer ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(customer_id, '"', '')
                    ),
                    ''
                ) AS customer_id,


                --------------------------------------------------------
                -- Clean Customer Unique ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(customer_unique_id, '"', '')
                    ),
                    ''
                ) AS customer_unique_id,


                --------------------------------------------------------
                -- ZIP CODE
                -- Keep as VARCHAR because it is a code
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(customer_zip_code_prefix, '"', '')
                    ),
                    ''
                ) AS customer_zip_raw,


                --------------------------------------------------------
                -- Standardize City
                --------------------------------------------------------
                LOWER(
                    NULLIF(
                        TRIM(
                            REPLACE(customer_city, '"', '')
                        ),
                        ''
                    )
                ) AS customer_city,


                --------------------------------------------------------
                -- Standardize State
                --------------------------------------------------------
                UPPER(
                    NULLIF(
                        TRIM(
                            REPLACE(customer_state, '"', '')
                        ),
                        ''
                    )
                ) AS customer_state,


                load_id,
                load_datetime,
                source_file

            FROM bronze.customers

            WHERE load_id > @LastWatermark
        ),

        CleanedCustomers AS
        (
            SELECT

                customer_id,
                customer_unique_id,

                --------------------------------------------------------
                -- Preserve ZIP exactly after cleaning
                --------------------------------------------------------
                customer_zip_raw AS customer_zip_code_prefix,

                customer_zip_raw,
                customer_city,
                customer_state,

                load_id,
                load_datetime,
                source_file

            FROM RawCustomers
        ),

        LatestCustomers AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY customer_id
                    ORDER BY
                        load_datetime DESC,
                        load_id DESC
                ) AS rn

            FROM CleanedCustomers
        )


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            customer_id,
            customer_unique_id,
            customer_zip_code_prefix,
            customer_city,
            customer_state,

            load_id AS source_load_id,
            load_datetime AS source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                WHEN customer_id IS NULL
                    THEN 'REJECTED'

                WHEN customer_unique_id IS NULL
                    THEN 'REJECTED'

                WHEN customer_zip_raw IS NOT NULL
                     AND
                     (
                         LEN(customer_zip_raw) <> 5
                         OR customer_zip_raw LIKE '%[^0-9]%'
                     )
                    THEN 'CHECK'

                WHEN customer_city IS NULL
                    THEN 'CHECK'

                WHEN customer_state IS NULL
                    THEN 'CHECK'

                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN customer_id IS NULL
                    THEN 'Missing customer_id'

                WHEN customer_unique_id IS NULL
                    THEN 'Missing customer_unique_id'

                WHEN customer_zip_raw IS NOT NULL
                     AND
                     (
                         LEN(customer_zip_raw) <> 5
                         OR customer_zip_raw LIKE '%[^0-9]%'
                     )
                    THEN 'Invalid customer_zip_code_prefix'

                WHEN customer_city IS NULL
                    THEN 'Missing customer_city'

                WHEN customer_state IS NULL
                    THEN 'Missing customer_state'

                ELSE NULL

            END AS data_quality_reason


        INTO #CleanCustomers

        FROM LatestCustomers

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected = COUNT(*)
        FROM #CleanCustomers
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck = COUNT(*)
        FROM #CleanCustomers
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Customers
        ----------------------------------------------------------------
        UPDATE s
        SET
            customer_unique_id =
                c.customer_unique_id,

            customer_zip_code_prefix =
                c.customer_zip_code_prefix,

            customer_city =
                c.customer_city,

            customer_state =
                c.customer_state,

            data_quality_status =
                c.data_quality_status,

            data_quality_reason =
                c.data_quality_reason,

            source_load_id =
                c.source_load_id,

            source_load_datetime =
                c.source_load_datetime,

            source_file =
                c.source_file

        FROM silver.customers s

        INNER JOIN #CleanCustomers c
            ON s.customer_id = c.customer_id

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND c.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Customers
        ----------------------------------------------------------------
        INSERT INTO silver.customers
        (
            customer_id,
            customer_unique_id,

            customer_zip_code_prefix,
            customer_city,
            customer_state,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT
            c.customer_id,
            c.customer_unique_id,

            c.customer_zip_code_prefix,
            c.customer_city,
            c.customer_state,

            c.data_quality_status,
            c.data_quality_reason,

            c.source_load_id,
            c.source_load_datetime,
            c.source_file

        FROM #CleanCustomers c

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.customers s
            WHERE s.customer_id = c.customer_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Update Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return Result
        ----------------------------------------------------------------
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_delivery]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_silver_delivery]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_Delivery',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New / Changed Orders in Silver
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(source_load_id),
            @RowsExtracted = COUNT(*)
        FROM silver.orders
        WHERE source_load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. No New Data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;


            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;


            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Clean + Transform Delivery Data
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanDelivery;


        SELECT

            ------------------------------------------------------------
            -- Identifiers
            ------------------------------------------------------------
            order_id,
            customer_id,


            ------------------------------------------------------------
            -- Dates
            ------------------------------------------------------------
            order_purchase_timestamp,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,


            ------------------------------------------------------------
            -- Delivery Days
            --
            -- Actual customer delivery - purchase
            ------------------------------------------------------------
            CASE
                WHEN
                    order_purchase_timestamp IS NOT NULL
                    AND order_delivered_customer_date IS NOT NULL
                THEN
                    DATEDIFF(
                        DAY,
                        order_purchase_timestamp,
                        order_delivered_customer_date
                    )
                ELSE NULL
            END AS delivery_days,


            ------------------------------------------------------------
            -- Delivery Delay
            --
            -- Actual delivery - estimated delivery
            ------------------------------------------------------------
            CASE
                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_estimated_delivery_date IS NOT NULL
                THEN
                    DATEDIFF(
                        DAY,
                        order_estimated_delivery_date,
                        order_delivered_customer_date
                    )
                ELSE NULL
            END AS delivery_delay_days,


            ------------------------------------------------------------
            -- Delivery Status
            ------------------------------------------------------------
            CASE

                WHEN order_delivered_customer_date IS NULL
                    THEN 'Not Delivered'

                WHEN
                    order_estimated_delivery_date IS NULL
                    THEN 'Delivered - No Estimate'

                WHEN
                    DATEDIFF(
                        DAY,
                        order_estimated_delivery_date,
                        order_delivered_customer_date
                    ) > 0
                    THEN 'Late'

                WHEN
                    DATEDIFF(
                        DAY,
                        order_estimated_delivery_date,
                        order_delivered_customer_date
                    ) = 0
                    THEN 'On Time'

                WHEN
                    DATEDIFF(
                        DAY,
                        order_estimated_delivery_date,
                        order_delivered_customer_date
                    ) < 0
                    THEN 'Early'

            END AS delivery_status,


            ------------------------------------------------------------
            -- Source Metadata
            ------------------------------------------------------------
            source_load_id,
            source_load_datetime,
            source_file


        INTO #CleanDelivery

        FROM silver.orders

        WHERE source_load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            order_id,
            customer_id,

            order_purchase_timestamp,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,

            delivery_days,
            delivery_delay_days,
            delivery_status,

            source_load_id,
            source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'REJECTED'

                WHEN order_purchase_timestamp IS NULL
                    THEN 'CHECK'

                WHEN
                    order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_carrier_date
                        < order_purchase_timestamp
                    THEN 'CHECK'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_purchase_timestamp
                    THEN 'CHECK'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_delivered_carrier_date
                    THEN 'CHECK'

                WHEN
                    order_estimated_delivery_date IS NOT NULL
                    AND order_estimated_delivery_date
                        < order_purchase_timestamp
                    THEN 'CHECK'

                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'Missing order_id'

                WHEN order_purchase_timestamp IS NULL
                    THEN 'Missing purchase timestamp'

                WHEN
                    order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_carrier_date
                        < order_purchase_timestamp
                    THEN 'Carrier delivery before purchase'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_purchase_timestamp
                    THEN 'Customer delivery before purchase'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_delivered_carrier_date
                    THEN 'Customer delivery before carrier'

                WHEN
                    order_estimated_delivery_date IS NOT NULL
                    AND order_estimated_delivery_date
                        < order_purchase_timestamp
                    THEN 'Estimated delivery before purchase'

                ELSE NULL

            END AS data_quality_reason


        INTO #ValidatedDelivery

        FROM #CleanDelivery;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected =
                COUNT(*)
        FROM #ValidatedDelivery
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck =
                COUNT(*)
        FROM #ValidatedDelivery
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Delivery Records
        ----------------------------------------------------------------
        UPDATE s
        SET

            customer_id =
                v.customer_id,

            order_purchase_timestamp =
                v.order_purchase_timestamp,

            order_delivered_carrier_date =
                v.order_delivered_carrier_date,

            order_delivered_customer_date =
                v.order_delivered_customer_date,

            order_estimated_delivery_date =
                v.order_estimated_delivery_date,

            delivery_days =
                v.delivery_days,

            delivery_delay_days =
                v.delivery_delay_days,

            delivery_status =
                v.delivery_status,

            data_quality_status =
                v.data_quality_status,

            data_quality_reason =
                v.data_quality_reason,

            source_load_id =
                v.source_load_id,

            source_load_datetime =
                v.source_load_datetime,

            source_file =
                v.source_file

        FROM silver.delivery s

        INNER JOIN #ValidatedDelivery v
            ON s.order_id = v.order_id

        WHERE v.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND v.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Delivery Records
        ----------------------------------------------------------------
        INSERT INTO silver.delivery
        (
            order_id,
            customer_id,

            order_purchase_timestamp,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,

            delivery_days,
            delivery_delay_days,
            delivery_status,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT

            v.order_id,
            v.customer_id,

            v.order_purchase_timestamp,
            v.order_delivered_carrier_date,
            v.order_delivered_customer_date,
            v.order_estimated_delivery_date,

            v.delivery_days,
            v.delivery_delay_days,
            v.delivery_status,

            v.data_quality_status,
            v.data_quality_reason,

            v.source_load_id,
            v.source_load_datetime,
            v.source_file

        FROM #ValidatedDelivery v

        WHERE v.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.delivery s
            WHERE s.order_id = v.order_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit Transaction
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Update Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return Result
        ----------------------------------------------------------------
        SELECT

            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_order_items]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_silver_order_items]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_OrderItems',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New Bronze Data
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(load_id),
            @RowsExtracted = COUNT(*)
        FROM bronze.order_items
        WHERE load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. No New Data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;

            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;

            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Clean + Transform + Deduplicate
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanOrderItems;

        ;WITH CleanedOrderItems AS
        (
            SELECT

                --------------------------------------------------------
                -- Clean Order ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(order_id, '"', '')
                    ),
                    ''
                ) AS order_id,


                --------------------------------------------------------
                -- Convert Order Item ID
                --------------------------------------------------------
                TRY_CONVERT
                (
                    INT,
                    NULLIF(
                        TRIM(
                            REPLACE(order_item_id, '"', '')
                        ),
                        ''
                    )
                ) AS order_item_id,


                --------------------------------------------------------
                -- Clean Product ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(product_id, '"', '')
                    ),
                    ''
                ) AS product_id,


                --------------------------------------------------------
                -- Clean Seller ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(seller_id, '"', '')
                    ),
                    ''
                ) AS seller_id,


                --------------------------------------------------------
                -- Convert Shipping Limit Date
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DATETIME2,
                    NULLIF(
                        TRIM(
                            REPLACE(shipping_limit_date, '"', '')
                        ),
                        ''
                    )
                ) AS shipping_limit_date,


                --------------------------------------------------------
                -- Convert Price
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DECIMAL(18,2),
                    NULLIF(
                        TRIM(
                            REPLACE(price, '"', '')
                        ),
                        ''
                    )
                ) AS price,


                --------------------------------------------------------
                -- Convert Freight
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DECIMAL(18,2),
                    NULLIF(
                        TRIM(
                            REPLACE(freight_value, '"', '')
                        ),
                        ''
                    )
                ) AS freight_value,


                load_id,
                load_datetime,
                source_file

            FROM bronze.order_items

            WHERE load_id > @LastWatermark
        ),

        LatestOrderItems AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        order_id,
                        order_item_id
                    ORDER BY
                        load_datetime DESC,
                        load_id DESC
                ) AS rn

            FROM CleanedOrderItems
        )


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            order_id,
            order_item_id,
            product_id,
            seller_id,

            shipping_limit_date,
            price,
            freight_value,

            load_id AS source_load_id,
            load_datetime AS source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'REJECTED'

                WHEN order_item_id IS NULL
                    THEN 'REJECTED'

                WHEN order_item_id <= 0
                    THEN 'REJECTED'

                WHEN product_id IS NULL
                    THEN 'REJECTED'

                WHEN seller_id IS NULL
                    THEN 'REJECTED'

                WHEN price IS NULL
                    THEN 'CHECK'

                WHEN price < 0
                    THEN 'CHECK'

                WHEN freight_value IS NULL
                    THEN 'CHECK'

                WHEN freight_value < 0
                    THEN 'CHECK'

                WHEN
                    shipping_limit_date IS NULL
                    THEN 'CHECK'

                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'Missing order_id'

                WHEN order_item_id IS NULL
                    THEN 'Missing or invalid order_item_id'

                WHEN order_item_id <= 0
                    THEN 'Invalid order_item_id'

                WHEN product_id IS NULL
                    THEN 'Missing product_id'

                WHEN seller_id IS NULL
                    THEN 'Missing seller_id'

                WHEN price IS NULL
                    THEN 'Missing or invalid price'

                WHEN price < 0
                    THEN 'Negative price'

                WHEN freight_value IS NULL
                    THEN 'Missing or invalid freight_value'

                WHEN freight_value < 0
                    THEN 'Negative freight_value'

                WHEN shipping_limit_date IS NULL
                    THEN 'Missing or invalid shipping_limit_date'

                ELSE NULL

            END AS data_quality_reason


        INTO #CleanOrderItems

        FROM LatestOrderItems

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected =
                COUNT(*)
        FROM #CleanOrderItems
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck =
                COUNT(*)
        FROM #CleanOrderItems
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Records
        ----------------------------------------------------------------
        UPDATE s
        SET
            product_id = c.product_id,
            seller_id = c.seller_id,

            shipping_limit_date =
                c.shipping_limit_date,

            price =
                c.price,

            freight_value =
                c.freight_value,

            data_quality_status =
                c.data_quality_status,

            data_quality_reason =
                c.data_quality_reason,

            source_load_id =
                c.source_load_id,

            source_load_datetime =
                c.source_load_datetime,

            source_file =
                c.source_file

        FROM silver.order_items s

        INNER JOIN #CleanOrderItems c
            ON s.order_id = c.order_id
           AND s.order_item_id = c.order_item_id

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND c.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Records
        ----------------------------------------------------------------
        INSERT INTO silver.order_items
        (
            order_id,
            order_item_id,
            product_id,
            seller_id,

            shipping_limit_date,
            price,
            freight_value,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT
            c.order_id,
            c.order_item_id,
            c.product_id,
            c.seller_id,

            c.shipping_limit_date,
            c.price,
            c.freight_value,

            c.data_quality_status,
            c.data_quality_reason,

            c.source_load_id,
            c.source_load_datetime,
            c.source_file

        FROM #CleanOrderItems c

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.order_items s
            WHERE s.order_id = c.order_id
              AND s.order_item_id = c.order_item_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded Rows
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit Transaction
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Update Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return Result
        ----------------------------------------------------------------
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY


    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_order_payments]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_silver_order_payments]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_OrderPayments',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New Bronze Data
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(load_id),
            @RowsExtracted = COUNT(*)
        FROM bronze.order_payments
        WHERE load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. No New Data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;


            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;


            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Clean + Transform + Deduplicate
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanPayments;


        ;WITH RawPayments AS
        (
            SELECT

                --------------------------------------------------------
                -- Clean Order ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(order_id, '"', '')
                    ),
                    ''
                ) AS order_id,


                --------------------------------------------------------
                -- Keep raw sequential for validation
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(payment_sequential, '"', '')
                    ),
                    ''
                ) AS payment_sequential_raw,


                --------------------------------------------------------
                -- Standardize Payment Type
                --------------------------------------------------------
                LOWER(
                    NULLIF(
                        TRIM(
                            REPLACE(payment_type, '"', '')
                        ),
                        ''
                    )
                ) AS payment_type,


                --------------------------------------------------------
                -- Keep raw installments for validation
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(payment_installments, '"', '')
                    ),
                    ''
                ) AS payment_installments_raw,


                --------------------------------------------------------
                -- Keep raw value for validation
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(payment_value, '"', '')
                    ),
                    ''
                ) AS payment_value_raw,


                load_id,
                load_datetime,
                source_file

            FROM bronze.order_payments

            WHERE load_id > @LastWatermark
        ),

        CleanedPayments AS
        (
            SELECT

                order_id,

                --------------------------------------------------------
                -- Convert Sequential
                --------------------------------------------------------
                TRY_CONVERT(
                    INT,
                    payment_sequential_raw
                ) AS payment_sequential,


                --------------------------------------------------------
                -- Payment Type
                --------------------------------------------------------
                payment_type,


                --------------------------------------------------------
                -- Convert Installments
                --------------------------------------------------------
                TRY_CONVERT(
                    INT,
                    payment_installments_raw
                ) AS payment_installments,


                --------------------------------------------------------
                -- Convert Payment Value
                --------------------------------------------------------
                TRY_CONVERT(
                    DECIMAL(18,2),
                    payment_value_raw
                ) AS payment_value,


                --------------------------------------------------------
                -- Raw values for Data Quality
                --------------------------------------------------------
                payment_sequential_raw,
                payment_installments_raw,
                payment_value_raw,


                load_id,
                load_datetime,
                source_file

            FROM RawPayments
        ),

        LatestPayments AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        order_id,
                        payment_sequential
                    ORDER BY
                        load_datetime DESC,
                        load_id DESC
                ) AS rn

            FROM CleanedPayments
        )


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            order_id,
            payment_sequential,
            payment_type,
            payment_installments,
            payment_value,

            load_id AS source_load_id,
            load_datetime AS source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                --------------------------------------------------------
                -- Key fields
                --------------------------------------------------------
                WHEN order_id IS NULL
                    THEN 'REJECTED'

                WHEN payment_sequential IS NULL
                    THEN 'REJECTED'

                WHEN payment_sequential <= 0
                    THEN 'REJECTED'


                --------------------------------------------------------
                -- Payment Type
                --------------------------------------------------------
                WHEN payment_type IS NULL
                    THEN 'CHECK'


                --------------------------------------------------------
                -- Installments
                --------------------------------------------------------
                WHEN payment_installments IS NULL
                     AND payment_installments_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN payment_installments < 0
                    THEN 'CHECK'


                --------------------------------------------------------
                -- Payment Value
                --------------------------------------------------------
                WHEN payment_value IS NULL
                     AND payment_value_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN payment_value < 0
                    THEN 'CHECK'


                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'Missing order_id'

                WHEN payment_sequential IS NULL
                    THEN 'Missing or invalid payment_sequential'

                WHEN payment_sequential <= 0
                    THEN 'Invalid payment_sequential'

                WHEN payment_type IS NULL
                    THEN 'Missing payment_type'

                WHEN payment_installments IS NULL
                     AND payment_installments_raw IS NOT NULL
                    THEN 'Invalid payment_installments'

                WHEN payment_installments < 0
                    THEN 'Negative payment_installments'

                WHEN payment_value IS NULL
                     AND payment_value_raw IS NOT NULL
                    THEN 'Invalid payment_value'

                WHEN payment_value < 0
                    THEN 'Negative payment_value'

                ELSE NULL

            END AS data_quality_reason


        INTO #CleanPayments

        FROM LatestPayments

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected = COUNT(*)
        FROM #CleanPayments
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck = COUNT(*)
        FROM #CleanPayments
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Payments
        ----------------------------------------------------------------
        UPDATE s
        SET
            payment_type =
                c.payment_type,

            payment_installments =
                c.payment_installments,

            payment_value =
                c.payment_value,

            data_quality_status =
                c.data_quality_status,

            data_quality_reason =
                c.data_quality_reason,

            source_load_id =
                c.source_load_id,

            source_load_datetime =
                c.source_load_datetime,

            source_file =
                c.source_file

        FROM silver.order_payments s

        INNER JOIN #CleanPayments c
            ON s.order_id = c.order_id
           AND s.payment_sequential = c.payment_sequential

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND c.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Payments
        ----------------------------------------------------------------
        INSERT INTO silver.order_payments
        (
            order_id,
            payment_sequential,
            payment_type,
            payment_installments,
            payment_value,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT
            c.order_id,
            c.payment_sequential,
            c.payment_type,
            c.payment_installments,
            c.payment_value,

            c.data_quality_status,
            c.data_quality_reason,

            c.source_load_id,
            c.source_load_datetime,
            c.source_file

        FROM #CleanPayments c

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.order_payments s
            WHERE s.order_id = c.order_id
              AND s.payment_sequential = c.payment_sequential
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Update Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return Result
        ----------------------------------------------------------------
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_orders]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-------------------procedure
CREATE   PROCEDURE [etl].[usp_load_silver_orders]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_Orders',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New Bronze Rows
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(load_id),
            @RowsExtracted = COUNT(*)
        FROM bronze.orders
        WHERE load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. Stop if no new data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;

            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;

            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Clean + Transform + Deduplicate
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanOrders;


        ;WITH CleanedOrders AS
        (
            SELECT

                --------------------------------------------------------
                -- Order ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(order_id, '"', '')
                    ),
                    ''
                ) AS order_id,


                --------------------------------------------------------
                -- Customer ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(customer_id, '"', '')
                    ),
                    ''
                ) AS customer_id,


                --------------------------------------------------------
                -- Standardize Order Status
                --------------------------------------------------------
                UPPER(
                    NULLIF(
                        TRIM(
                            REPLACE(order_status, '"', '')
                        ),
                        ''
                    )
                ) AS order_status,


                --------------------------------------------------------
                -- Purchase Date
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DATETIME2,
                    NULLIF(
                        TRIM(
                            REPLACE(order_purchase_timestamp, '"', '')
                        ),
                        ''
                    )
                ) AS order_purchase_timestamp,


                --------------------------------------------------------
                -- Approved Date
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DATETIME2,
                    NULLIF(
                        TRIM(
                            REPLACE(order_approved_at, '"', '')
                        ),
                        ''
                    )
                ) AS order_approved_at,


                --------------------------------------------------------
                -- Carrier Date
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DATETIME2,
                    NULLIF(
                        TRIM(
                            REPLACE(order_delivered_carrier_date, '"', '')
                        ),
                        ''
                    )
                ) AS order_delivered_carrier_date,


                --------------------------------------------------------
                -- Customer Delivery Date
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DATETIME2,
                    NULLIF(
                        TRIM(
                            REPLACE(order_delivered_customer_date, '"', '')
                        ),
                        ''
                    )
                ) AS order_delivered_customer_date,


                --------------------------------------------------------
                -- Estimated Delivery Date
                --------------------------------------------------------
                TRY_CONVERT
                (
                    DATETIME2,
                    NULLIF(
                        TRIM(
                            REPLACE(order_estimated_delivery_date, '"', '')
                        ),
                        ''
                    )
                ) AS order_estimated_delivery_date,


                load_id,
                load_datetime,
                source_file

            FROM bronze.orders

            WHERE load_id > @LastWatermark
        ),

        LatestOrders AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY order_id
                    ORDER BY
                        load_datetime DESC,
                        load_id DESC
                ) AS rn

            FROM CleanedOrders
        )


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            order_id,
            customer_id,
            order_status,

            order_purchase_timestamp,
            order_approved_at,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,

            load_id AS source_load_id,
            load_datetime AS source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'REJECTED'

                WHEN order_purchase_timestamp IS NULL
                    THEN 'CHECK'

                WHEN order_status IS NULL
                    THEN 'CHECK'

                WHEN
                    order_approved_at IS NOT NULL
                    AND order_approved_at < order_purchase_timestamp
                    THEN 'CHECK'

                WHEN
                    order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_carrier_date
                        < order_purchase_timestamp
                    THEN 'CHECK'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_purchase_timestamp
                    THEN 'CHECK'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_delivered_carrier_date
                    THEN 'CHECK'

                WHEN
                    order_estimated_delivery_date IS NOT NULL
                    AND order_estimated_delivery_date
                        < order_purchase_timestamp
                    THEN 'CHECK'

                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN order_id IS NULL
                    THEN 'Missing order_id'

                WHEN order_purchase_timestamp IS NULL
                    THEN 'Missing or invalid purchase timestamp'

                WHEN order_status IS NULL
                    THEN 'Missing order status'

                WHEN
                    order_approved_at IS NOT NULL
                    AND order_approved_at < order_purchase_timestamp
                    THEN 'Approved before purchase'

                WHEN
                    order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_carrier_date
                        < order_purchase_timestamp
                    THEN 'Carrier delivery before purchase'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_purchase_timestamp
                    THEN 'Customer delivery before purchase'

                WHEN
                    order_delivered_customer_date IS NOT NULL
                    AND order_delivered_carrier_date IS NOT NULL
                    AND order_delivered_customer_date
                        < order_delivered_carrier_date
                    THEN 'Customer delivery before carrier'

                WHEN
                    order_estimated_delivery_date IS NOT NULL
                    AND order_estimated_delivery_date
                        < order_purchase_timestamp
                    THEN 'Estimated delivery before purchase'

                ELSE NULL

            END AS data_quality_reason


        INTO #CleanOrders

        FROM LatestOrders

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected =
                COUNT(*)
        FROM #CleanOrders
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck =
                COUNT(*)
        FROM #CleanOrders
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Valid / Check Orders
        ----------------------------------------------------------------
        UPDATE s
        SET
            customer_id = c.customer_id,
            order_status = c.order_status,

            order_purchase_timestamp =
                c.order_purchase_timestamp,

            order_approved_at =
                c.order_approved_at,

            order_delivered_carrier_date =
                c.order_delivered_carrier_date,

            order_delivered_customer_date =
                c.order_delivered_customer_date,

            order_estimated_delivery_date =
                c.order_estimated_delivery_date,

            data_quality_status =
                c.data_quality_status,

            data_quality_reason =
                c.data_quality_reason,

            source_load_id =
                c.source_load_id,

            source_load_datetime =
                c.source_load_datetime,

            source_file =
                c.source_file

        FROM silver.orders s

        INNER JOIN #CleanOrders c
            ON s.order_id = c.order_id

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND c.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Orders
        ----------------------------------------------------------------
        INSERT INTO silver.orders
        (
            order_id,
            customer_id,
            order_status,

            order_purchase_timestamp,
            order_approved_at,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT
            c.order_id,
            c.customer_id,
            c.order_status,

            c.order_purchase_timestamp,
            c.order_approved_at,
            c.order_delivered_carrier_date,
            c.order_delivered_customer_date,
            c.order_estimated_delivery_date,

            c.data_quality_status,
            c.data_quality_reason,

            c.source_load_id,
            c.source_load_datetime,
            c.source_file

        FROM #CleanOrders c

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.orders s
            WHERE s.order_id = c.order_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded Rows
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit Transaction
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return ETL Result
        ----------------------------------------------------------------
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY


    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Error
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_products]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_silver_products]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_Products',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New Bronze Data
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(load_id),
            @RowsExtracted = COUNT(*)
        FROM bronze.products
        WHERE load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. No New Data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;


            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;


            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Raw + Clean + Transform
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanProducts;


        ;WITH RawProducts AS
        (
            SELECT

                --------------------------------------------------------
                -- Clean Product ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(product_id, '"', '')
                    ),
                    ''
                ) AS product_id,


                --------------------------------------------------------
                -- Clean Product Category
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(product_category_name, '"', '')
                    ),
                    ''
                ) AS product_category_name,


                --------------------------------------------------------
                -- Keep original values for Data Quality checks
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(product_name_lenght, '"', '')
                    ),
                    ''
                ) AS product_name_length_raw,


                NULLIF(
                    TRIM(
                        REPLACE(product_description_lenght, '"', '')
                    ),
                    ''
                ) AS product_description_length_raw,


                NULLIF(
                    TRIM(
                        REPLACE(product_photos_qty, '"', '')
                    ),
                    ''
                ) AS product_photos_qty_raw,


                NULLIF(
                    TRIM(
                        REPLACE(product_weight_g, '"', '')
                    ),
                    ''
                ) AS product_weight_g_raw,


                NULLIF(
                    TRIM(
                        REPLACE(product_length_cm, '"', '')
                    ),
                    ''
                ) AS product_length_cm_raw,


                NULLIF(
                    TRIM(
                        REPLACE(product_height_cm, '"', '')
                    ),
                    ''
                ) AS product_height_cm_raw,


                NULLIF(
                    TRIM(
                        REPLACE(product_width_cm, '"', '')
                    ),
                    ''
                ) AS product_width_cm_raw,


                load_id,
                load_datetime,
                source_file

            FROM bronze.products

            WHERE load_id > @LastWatermark
        ),

        CleanedProducts AS
        (
            SELECT

                product_id,
                product_category_name,

                --------------------------------------------------------
                -- Convert numeric fields
                --------------------------------------------------------
                TRY_CONVERT(
                    INT,
                    product_name_length_raw
                ) AS product_name_length,


                TRY_CONVERT(
                    INT,
                    product_description_length_raw
                ) AS product_description_length,


                TRY_CONVERT(
                    INT,
                    product_photos_qty_raw
                ) AS product_photos_qty,


                TRY_CONVERT(
                    DECIMAL(18,2),
                    product_weight_g_raw
                ) AS product_weight_g,


                TRY_CONVERT(
                    DECIMAL(18,2),
                    product_length_cm_raw
                ) AS product_length_cm,


                TRY_CONVERT(
                    DECIMAL(18,2),
                    product_height_cm_raw
                ) AS product_height_cm,


                TRY_CONVERT(
                    DECIMAL(18,2),
                    product_width_cm_raw
                ) AS product_width_cm,


                --------------------------------------------------------
                -- Keep raw cleaned values for Validation
                --------------------------------------------------------
                product_name_length_raw,
                product_description_length_raw,
                product_photos_qty_raw,
                product_weight_g_raw,
                product_length_cm_raw,
                product_height_cm_raw,
                product_width_cm_raw,


                load_id,
                load_datetime,
                source_file

            FROM RawProducts
        ),

        LatestProducts AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY product_id
                    ORDER BY
                        load_datetime DESC,
                        load_id DESC
                ) AS rn

            FROM CleanedProducts
        )


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            product_id,
            product_category_name,

            product_name_length,
            product_description_length,
            product_photos_qty,

            product_weight_g,
            product_length_cm,
            product_height_cm,
            product_width_cm,

            load_id AS source_load_id,
            load_datetime AS source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                WHEN product_id IS NULL
                    THEN 'REJECTED'

                WHEN product_category_name IS NULL
                    THEN 'CHECK'

                WHEN product_name_length IS NULL
                     AND product_name_length_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_description_length IS NULL
                     AND product_description_length_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_photos_qty IS NULL
                     AND product_photos_qty_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_weight_g IS NULL
                     AND product_weight_g_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_length_cm IS NULL
                     AND product_length_cm_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_height_cm IS NULL
                     AND product_height_cm_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_width_cm IS NULL
                     AND product_width_cm_raw IS NOT NULL
                    THEN 'CHECK'

                WHEN product_name_length < 0
                    THEN 'CHECK'

                WHEN product_description_length < 0
                    THEN 'CHECK'

                WHEN product_photos_qty < 0
                    THEN 'CHECK'

                WHEN product_weight_g < 0
                    THEN 'CHECK'

                WHEN product_length_cm < 0
                    THEN 'CHECK'

                WHEN product_height_cm < 0
                    THEN 'CHECK'

                WHEN product_width_cm < 0
                    THEN 'CHECK'

                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN product_id IS NULL
                    THEN 'Missing product_id'

                WHEN product_category_name IS NULL
                    THEN 'Missing product category'

                WHEN product_name_length IS NULL
                     AND product_name_length_raw IS NOT NULL
                    THEN 'Invalid product_name_length'

                WHEN product_description_length IS NULL
                     AND product_description_length_raw IS NOT NULL
                    THEN 'Invalid product_description_length'

                WHEN product_photos_qty IS NULL
                     AND product_photos_qty_raw IS NOT NULL
                    THEN 'Invalid product_photos_qty'

                WHEN product_weight_g IS NULL
                     AND product_weight_g_raw IS NOT NULL
                    THEN 'Invalid product_weight_g'

                WHEN product_length_cm IS NULL
                     AND product_length_cm_raw IS NOT NULL
                    THEN 'Invalid product_length_cm'

                WHEN product_height_cm IS NULL
                     AND product_height_cm_raw IS NOT NULL
                    THEN 'Invalid product_height_cm'

                WHEN product_width_cm IS NULL
                     AND product_width_cm_raw IS NOT NULL
                    THEN 'Invalid product_width_cm'

                WHEN product_name_length < 0
                    THEN 'Negative product_name_length'

                WHEN product_description_length < 0
                    THEN 'Negative product_description_length'

                WHEN product_photos_qty < 0
                    THEN 'Negative product_photos_qty'

                WHEN product_weight_g < 0
                    THEN 'Negative product_weight_g'

                WHEN product_length_cm < 0
                    THEN 'Negative product_length_cm'

                WHEN product_height_cm < 0
                    THEN 'Negative product_height_cm'

                WHEN product_width_cm < 0
                    THEN 'Negative product_width_cm'

                ELSE NULL

            END AS data_quality_reason


        INTO #CleanProducts

        FROM LatestProducts

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected = COUNT(*)
        FROM #CleanProducts
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck = COUNT(*)
        FROM #CleanProducts
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Products
        ----------------------------------------------------------------
        UPDATE s
        SET
            product_category_name =
                c.product_category_name,

            product_name_length =
                c.product_name_length,

            product_description_length =
                c.product_description_length,

            product_photos_qty =
                c.product_photos_qty,

            product_weight_g =
                c.product_weight_g,

            product_length_cm =
                c.product_length_cm,

            product_height_cm =
                c.product_height_cm,

            product_width_cm =
                c.product_width_cm,

            data_quality_status =
                c.data_quality_status,

            data_quality_reason =
                c.data_quality_reason,

            source_load_id =
                c.source_load_id,

            source_load_datetime =
                c.source_load_datetime,

            source_file =
                c.source_file

        FROM silver.products s

        INNER JOIN #CleanProducts c
            ON s.product_id = c.product_id

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND c.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Products
        ----------------------------------------------------------------
        INSERT INTO silver.products
        (
            product_id,
            product_category_name,

            product_name_length,
            product_description_length,
            product_photos_qty,

            product_weight_g,
            product_length_cm,
            product_height_cm,
            product_width_cm,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT
            c.product_id,
            c.product_category_name,

            c.product_name_length,
            c.product_description_length,
            c.product_photos_qty,

            c.product_weight_g,
            c.product_length_cm,
            c.product_height_cm,
            c.product_width_cm,

            c.data_quality_status,
            c.data_quality_reason,

            c.source_load_id,
            c.source_load_datetime,
            c.source_file

        FROM #CleanProducts c

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.products s
            WHERE s.product_id = c.product_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Update Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return Result
        ----------------------------------------------------------------
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
/****** Object:  StoredProcedure [etl].[usp_load_silver_sellers]    Script Date: 9/29/2026 1:33:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[usp_load_silver_sellers]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Variables
    ----------------------------------------------------------------
    DECLARE
        @PipelineName VARCHAR(100) = 'Olist_Silver_Sellers',
        @RunID BIGINT = NULL,
        @LastWatermark BIGINT = 0,
        @CurrentMaxLoadID BIGINT = NULL,
        @RowsExtracted INT = 0,
        @RowsLoaded INT = 0,
        @RowsUpdated INT = 0,
        @RowsInserted INT = 0,
        @RowsRejected INT = 0,
        @RowsCheck INT = 0;

    BEGIN TRY

        ----------------------------------------------------------------
        -- 2. Start Run Log
        ----------------------------------------------------------------
        INSERT INTO etl.Run_Log
        (
            pipeline_name,
            status
        )
        VALUES
        (
            @PipelineName,
            'Running'
        );

        SET @RunID = SCOPE_IDENTITY();


        ----------------------------------------------------------------
        -- 3. Get Last Watermark
        ----------------------------------------------------------------
        SELECT
            @LastWatermark =
                ISNULL(
                    TRY_CONVERT(BIGINT, watermark_value),
                    0
                )
        FROM etl.Pipeline_Control
        WHERE pipeline_name = @PipelineName;


        ----------------------------------------------------------------
        -- 4. Find New Bronze Data
        ----------------------------------------------------------------
        SELECT
            @CurrentMaxLoadID = MAX(load_id),
            @RowsExtracted = COUNT(*)
        FROM bronze.sellers
        WHERE load_id > @LastWatermark;


        ----------------------------------------------------------------
        -- 5. No New Data
        ----------------------------------------------------------------
        IF @RowsExtracted = 0
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Success',
                rows_extracted = 0,
                rows_loaded = 0,
                rows_rejected = 0
            WHERE run_id = @RunID;


            UPDATE etl.Pipeline_Control
            SET
                last_successful_run = SYSDATETIME()
            WHERE pipeline_name = @PipelineName;


            SELECT
                @RunID AS run_id,
                0 AS rows_extracted,
                0 AS rows_updated,
                0 AS rows_inserted,
                0 AS rows_loaded,
                0 AS rows_check,
                0 AS rows_rejected,
                'Success - No New Data' AS status;

            RETURN;
        END;


        ----------------------------------------------------------------
        -- 6. Clean + Transform + Deduplicate
        ----------------------------------------------------------------
        DROP TABLE IF EXISTS #CleanSellers;


        ;WITH RawSellers AS
        (
            SELECT

                --------------------------------------------------------
                -- Clean Seller ID
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(seller_id, '"', '')
                    ),
                    ''
                ) AS seller_id,


                --------------------------------------------------------
                -- Clean ZIP
                -- Keep as VARCHAR because ZIP is a code
                --------------------------------------------------------
                NULLIF(
                    TRIM(
                        REPLACE(seller_zip_code_prefix, '"', '')
                    ),
                    ''
                ) AS seller_zip_raw,


                --------------------------------------------------------
                -- Standardize City
                --------------------------------------------------------
                LOWER(
                    NULLIF(
                        TRIM(
                            REPLACE(seller_city, '"', '')
                        ),
                        ''
                    )
                ) AS seller_city,


                --------------------------------------------------------
                -- Clean State Raw Value
                --------------------------------------------------------
                UPPER(
                    NULLIF(
                        TRIM(
                            REPLACE(seller_state, '"', '')
                        ),
                        ''
                    )
                ) AS seller_state_raw,


                load_id,
                load_datetime,
                source_file

            FROM bronze.sellers

            WHERE load_id > @LastWatermark
        ),

        CleanedSellers AS
        (
            SELECT

                seller_id,

                seller_zip_raw,

                seller_city,

                --------------------------------------------------------
                -- Standardize State Code
                --
                -- Normal values:
                -- SP, RJ, MG, etc.
                --
                -- Abnormal values:
                -- RIO DE JANEIRO, BRASIL,RJ
                -- RIO GRANDE DO SUL, BRASIL,RS
                --
                -- Extract the final 2 characters when commas exist.
                --------------------------------------------------------
                CASE
                    WHEN CHARINDEX(',', seller_state_raw) > 0
                        THEN RIGHT(
                            TRIM(seller_state_raw),
                            2
                        )
                    ELSE seller_state_raw
                END AS seller_state,

                load_id,
                load_datetime,
                source_file

            FROM RawSellers
        ),

        LatestSellers AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY seller_id
                    ORDER BY
                        load_datetime DESC,
                        load_id DESC
                ) AS rn

            FROM CleanedSellers
        )


        ----------------------------------------------------------------
        -- 7. Data Quality Classification
        ----------------------------------------------------------------
        SELECT

            seller_id,

            seller_zip_raw AS seller_zip_code_prefix,

            seller_city,
            seller_state,

            load_id AS source_load_id,
            load_datetime AS source_load_datetime,
            source_file,


            ------------------------------------------------------------
            -- Data Quality Status
            ------------------------------------------------------------
            CASE

                WHEN seller_id IS NULL
                    THEN 'REJECTED'

                WHEN seller_zip_raw IS NOT NULL
                     AND
                     (
                         LEN(seller_zip_raw) <> 5
                         OR seller_zip_raw LIKE '%[^0-9]%'
                     )
                    THEN 'CHECK'

                WHEN seller_city IS NULL
                    THEN 'CHECK'

                WHEN seller_state IS NULL
                    THEN 'CHECK'

                WHEN LEN(seller_state) <> 2
                    THEN 'CHECK'

                ELSE 'VALID'

            END AS data_quality_status,


            ------------------------------------------------------------
            -- Data Quality Reason
            ------------------------------------------------------------
            CASE

                WHEN seller_id IS NULL
                    THEN 'Missing seller_id'

                WHEN seller_zip_raw IS NOT NULL
                     AND
                     (
                         LEN(seller_zip_raw) <> 5
                         OR seller_zip_raw LIKE '%[^0-9]%'
                     )
                    THEN 'Invalid seller_zip_code_prefix'

                WHEN seller_city IS NULL
                    THEN 'Missing seller_city'

                WHEN seller_state IS NULL
                    THEN 'Missing seller_state'

                WHEN LEN(seller_state) <> 2
                    THEN 'Invalid seller_state_code'

                ELSE NULL

            END AS data_quality_reason


        INTO #CleanSellers

        FROM LatestSellers

        WHERE rn = 1;


        ----------------------------------------------------------------
        -- 8. Count Data Quality Results
        ----------------------------------------------------------------
        SELECT
            @RowsRejected = COUNT(*)
        FROM #CleanSellers
        WHERE data_quality_status = 'REJECTED';


        SELECT
            @RowsCheck = COUNT(*)
        FROM #CleanSellers
        WHERE data_quality_status = 'CHECK';


        ----------------------------------------------------------------
        -- 9. Begin Transaction
        ----------------------------------------------------------------
        BEGIN TRANSACTION;


        ----------------------------------------------------------------
        -- 10. Update Existing Sellers
        ----------------------------------------------------------------
        UPDATE s
        SET
            seller_zip_code_prefix =
                c.seller_zip_code_prefix,

            seller_city =
                c.seller_city,

            seller_state =
                c.seller_state,

            data_quality_status =
                c.data_quality_status,

            data_quality_reason =
                c.data_quality_reason,

            source_load_id =
                c.source_load_id,

            source_load_datetime =
                c.source_load_datetime,

            source_file =
                c.source_file

        FROM silver.sellers s

        INNER JOIN #CleanSellers c
            ON s.seller_id = c.seller_id

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND c.source_load_id > s.source_load_id;


        SET @RowsUpdated = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 11. Insert New Sellers
        ----------------------------------------------------------------
        INSERT INTO silver.sellers
        (
            seller_id,
            seller_zip_code_prefix,
            seller_city,
            seller_state,

            data_quality_status,
            data_quality_reason,

            source_load_id,
            source_load_datetime,
            source_file
        )

        SELECT
            c.seller_id,
            c.seller_zip_code_prefix,
            c.seller_city,
            c.seller_state,

            c.data_quality_status,
            c.data_quality_reason,

            c.source_load_id,
            c.source_load_datetime,
            c.source_file

        FROM #CleanSellers c

        WHERE c.data_quality_status IN
        (
            'VALID',
            'CHECK'
        )

        AND NOT EXISTS
        (
            SELECT 1
            FROM silver.sellers s
            WHERE s.seller_id = c.seller_id
        );


        SET @RowsInserted = @@ROWCOUNT;


        ----------------------------------------------------------------
        -- 12. Total Loaded
        ----------------------------------------------------------------
        SET @RowsLoaded =
            @RowsUpdated + @RowsInserted;


        ----------------------------------------------------------------
        -- 13. Update Watermark
        ----------------------------------------------------------------
        IF EXISTS
        (
            SELECT 1
            FROM etl.Pipeline_Control
            WHERE pipeline_name = @PipelineName
        )
        BEGIN

            UPDATE etl.Pipeline_Control
            SET
                watermark_value =
                    CONVERT(
                        VARCHAR(100),
                        @CurrentMaxLoadID
                    ),

                last_successful_run =
                    SYSDATETIME()

            WHERE pipeline_name = @PipelineName;

        END
        ELSE
        BEGIN

            INSERT INTO etl.Pipeline_Control
            (
                pipeline_name,
                watermark_value,
                last_successful_run,
                is_active
            )
            VALUES
            (
                @PipelineName,
                CONVERT(
                    VARCHAR(100),
                    @CurrentMaxLoadID
                ),
                SYSDATETIME(),
                1
            );

        END;


        ----------------------------------------------------------------
        -- 14. Commit
        ----------------------------------------------------------------
        COMMIT TRANSACTION;


        ----------------------------------------------------------------
        -- 15. Run Log
        ----------------------------------------------------------------
        UPDATE etl.Run_Log
        SET
            end_time = SYSDATETIME(),
            status = 'Success',
            rows_extracted = @RowsExtracted,
            rows_loaded = @RowsLoaded,
            rows_rejected = @RowsRejected
        WHERE run_id = @RunID;


        ----------------------------------------------------------------
        -- 16. Return Result
        ----------------------------------------------------------------
        SELECT
            @RunID AS run_id,
            @RowsExtracted AS rows_extracted,
            @RowsUpdated AS rows_updated,
            @RowsInserted AS rows_inserted,
            @RowsLoaded AS rows_loaded,
            @RowsCheck AS rows_check,
            @RowsRejected AS rows_rejected,
            'Success' AS status;


    END TRY

    BEGIN CATCH

        ----------------------------------------------------------------
        -- Rollback
        ----------------------------------------------------------------
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        ----------------------------------------------------------------
        -- Log Failure
        ----------------------------------------------------------------
        IF @RunID IS NOT NULL
        BEGIN

            UPDATE etl.Run_Log
            SET
                end_time = SYSDATETIME(),
                status = 'Failed',
                rows_extracted = @RowsExtracted,
                rows_loaded = @RowsLoaded,
                rows_rejected = @RowsRejected,
                error_message = ERROR_MESSAGE()
            WHERE run_id = @RunID;

        END;


        THROW;

    END CATCH;

END;
GO
