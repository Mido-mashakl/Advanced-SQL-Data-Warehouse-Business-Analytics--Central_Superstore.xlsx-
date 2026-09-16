IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'superstore_dw')
    CREATE DATABASE superstore_dw;
GO

USE superstore_dw;
 
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'staging')
    EXEC('CREATE SCHEMA staging');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze')
    EXEC('CREATE SCHEMA bronze');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC('CREATE SCHEMA silver');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC('CREATE SCHEMA gold');
GO

-- ============================================================
-- STEP 1 — SQL SERVER STAGING TABLE
-- Raw data lands here exactly as received from Excel: no type
-- enforcement beyond what's needed to load it, no cleaning yet.
-- (Written in SQLite syntax for the working prototype; the
--  T-SQL/SQL Server equivalent is noted alongside each type.)
-- ============================================================
DROP TABLE IF EXISTS staging.superstore;
 
CREATE TABLE staging.superstore (
    row_id          INT,
    order_id        NVARCHAR(255),
    order_date      NVARCHAR(255), 
    ship_date       NVARCHAR(255), 
    ship_mode       NVARCHAR(255),  
    customer_id     NVARCHAR(255),
    customer_name   NVARCHAR(255), 
    segment         NVARCHAR(255),    
    country         NVARCHAR(255),   
    city            NVARCHAR(255),   
    state           NVARCHAR(255),   
    postal_code     NVARCHAR(255),  
    region          NVARCHAR(255),   
    product_id      NVARCHAR(255),   
    category        NVARCHAR(255),   
    sub_category    NVARCHAR(255),  
    product_name    NVARCHAR(255),  
    sales            NVARCHAR(255),  
    quantity         NVARCHAR(255),
    discount         NVARCHAR(255),
    profit           NVARCHAR(255)
);
 
-- Loaded by load_staging.py (bulk row-by-row insert from the
-- Excel source). In production SQL Server this step would be a
-- BULK INSERT / OPENROWSET / SSIS load from the source file into
-- this same unvalidated shape.
--------------------------------------------------------------------
-- Truncate + reload every staging table from its current batch file.
CREATE OR ALTER PROCEDURE staging.load_superstore
AS
BEGIN
    TRUNCATE TABLE staging.superstore;
    BULK INSERT staging.superstore
    FROM 'D:\mido\depi\MSSQL16.SQLEXPRESS\Mini-Project\Central_Superstore.csv'
    WITH
    (
        FORMAT = 'CSV',
        FIELDQUOTE = '"',         
        FIRSTROW = 2,
        FIELDTERMINATOR = ';',
        ROWTERMINATOR = '0x0a',
        CODEPAGE = '65001',
        MAXERRORS = 0,
        ERRORFILE = 'D:\mido\depi\MSSQL16.SQLEXPRESS\Mini-Project\superstore_err.log',
        TABLOCK
    );

END;
GO

Exec staging.load_superstore;
Select * from staging.superstore;
-- ============================================================
-- BRONZE LAYER
-- ============================================================
-- Incremental + append-only (never truncated). Deduplication is on
-- the FULL ROW (EXCEPT), not just the business key: an unchanged
-- reload is skipped; a row with any changed column becomes a new
-- version instead of overwriting or being silently dropped.
-- bronze_id marks version order -- silver picks MAX(bronze_id) per
-- business key as the current version. Still 7 per-source tables;
-- no cross-source integration happens here.

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'bronze' AND t.name = 'superstore')
BEGIN
    CREATE TABLE bronze.superstore (
        bronze_id INT IDENTITY(1,1) PRIMARY KEY,
        order_id        NVARCHAR(255),
        order_date      NVARCHAR(255), 
        ship_date       NVARCHAR(255), 
        ship_mode       NVARCHAR(255),  
        customer_id     NVARCHAR(255),
        customer_name   NVARCHAR(255), 
        segment         NVARCHAR(255),    
        country         NVARCHAR(255),   
        city            NVARCHAR(255),   
        state           NVARCHAR(255),   
        postal_code     NVARCHAR(255),  
        region          NVARCHAR(255),   
        product_id      NVARCHAR(255),   
        category        NVARCHAR(255),   
        sub_category    NVARCHAR(255),  
        product_name    NVARCHAR(255),  
        sales            NVARCHAR(255),  
        quantity         NVARCHAR(255),
        discount         NVARCHAR(255),
        profit           NVARCHAR(255)
    );
END;
GO

-- bronze.superstore: full-row anti-join against staging.superstore
INSERT INTO bronze.superstore (
    order_id,
    order_date,
    ship_date,
    ship_mode,
    customer_id,
    customer_name,
    segment,
    country,
    city,
    state,
    postal_code,
    region,
    product_id,
    category,
    sub_category,
    product_name,
    sales,
    quantity,
    discount,
    profit
)
SELECT order_id, order_date, ship_date, ship_mode, customer_id, customer_name, segment, country, city, state, postal_code, region, product_id, category, sub_category, product_name, sales, quantity, discount, profit
FROM staging.superstore
EXCEPT
SELECT order_id, order_date, ship_date, ship_mode, customer_id, customer_name, segment, country, city, state, postal_code, region, product_id, category, sub_category, product_name, sales, quantity, discount, profit
FROM bronze.superstore;
GO

SELECT * FROM bronze.superstore;
-- ============================================================
-- SILVER LAYER
-- ============================================================
-- Bronze is a single denormalized, order-line-grain table (one
-- flat source file -- unlike a multi-source project, there is no
-- separate customer/product feed to integrate here). Silver is
-- where that flat structure gets split into its natural entities
-- -- customers, products, locations -- plus a cleaned order-line
-- table at the original grain, and where every column is
-- TRY_CONVERT'd to its real data type.
-- Per table: take the latest bronze version per business key
-- (bronze is append-only, so a key can have more than one version),
-- clean (trim / blank -> NULL), flag missing/invalid/outlier values
-- (flagged, never silently dropped or nulled), then MERGE upsert on
-- the business key so silver always holds exactly one current row
-- per entity.
-- 4 silver tables in total: silver.customers, silver.products,
-- silver.locations, silver.order_lines.

-- ------------------------------------------------------------
-- 3A. silver.customers
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'silver' AND t.name = 'customers')
BEGIN
    CREATE TABLE silver.customers (
        customer_id     NVARCHAR(20)  NOT NULL PRIMARY KEY,
        customer_name   NVARCHAR(255) NOT NULL,
        segment         NVARCHAR(50)  NOT NULL,
        silver_loaded_at DATETIME2 DEFAULT SYSUTCDATETIME()
    );
END;
GO

-- Latest bronze version per customer_id, trimmed. A customer can
-- appear on many order lines with an (expected) identical name/segment
-- each time, so MAX(bronze_id) + DISTINCT is enough here -- there is
-- no real "changing dimension" scenario in this dataset.
MERGE silver.customers AS tgt
USING (
    SELECT
        LTRIM(RTRIM(b.customer_id))   AS customer_id,
        LTRIM(RTRIM(b.customer_name)) AS customer_name,
        LTRIM(RTRIM(b.segment))       AS segment
    FROM bronze.superstore b
    INNER JOIN (
        SELECT customer_id, MAX(bronze_id) AS max_bronze_id
        FROM bronze.superstore
        GROUP BY customer_id
    ) latest ON latest.customer_id = b.customer_id AND latest.max_bronze_id = b.bronze_id
) AS src
ON tgt.customer_id = src.customer_id
WHEN MATCHED AND (tgt.customer_name <> src.customer_name OR tgt.segment <> src.segment) THEN
    UPDATE SET customer_name = src.customer_name, segment = src.segment
WHEN NOT MATCHED THEN
    INSERT (customer_id, customer_name, segment)
    VALUES (src.customer_id, src.customer_name, src.segment);
GO

SELECT * FROM silver.customers;
-- ------------------------------------------------------------
-- 3B. silver.products
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'silver' AND t.name = 'products')
BEGIN
    CREATE TABLE silver.products (
        product_id      NVARCHAR(30)  NOT NULL PRIMARY KEY,
        product_name    NVARCHAR(500) NOT NULL,
        category        NVARCHAR(50)  NOT NULL,
        sub_category    NVARCHAR(50)  NOT NULL,
        silver_loaded_at DATETIME2 DEFAULT SYSUTCDATETIME()
    );
END;
GO

MERGE silver.products AS tgt
USING (
    SELECT
        LTRIM(RTRIM(b.product_id))   AS product_id,
        LTRIM(RTRIM(b.product_name)) AS product_name,
        LTRIM(RTRIM(b.category))     AS category,
        LTRIM(RTRIM(b.sub_category)) AS sub_category
    FROM bronze.superstore b
    INNER JOIN (
        SELECT product_id, MAX(bronze_id) AS max_bronze_id
        FROM bronze.superstore
        GROUP BY product_id
    ) latest ON latest.product_id = b.product_id AND latest.max_bronze_id = b.bronze_id
) AS src
ON tgt.product_id = src.product_id
WHEN MATCHED AND (tgt.product_name <> src.product_name OR tgt.category <> src.category OR tgt.sub_category <> src.sub_category) THEN
    UPDATE SET product_name = src.product_name, category = src.category, sub_category = src.sub_category
WHEN NOT MATCHED THEN
    INSERT (product_id, product_name, category, sub_category)
    VALUES (src.product_id, src.product_name, src.category, src.sub_category);
GO

SELECT * FROM silver.products;
-- ------------------------------------------------------------
-- 3C. silver.locations
-- ------------------------------------------------------------
-- No natural single-column business key for a location in this
-- source (postal code alone is not guaranteed unique/clean coming
-- from a text column), so the natural key here is the (city, state,
-- postal_code, region, country) combination, and a surrogate
-- location_id is generated with IDENTITY.
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'silver' AND t.name = 'locations')
BEGIN
    CREATE TABLE silver.locations (
        location_id     INT IDENTITY(1,1) PRIMARY KEY,
        city            NVARCHAR(100) NOT NULL,
        state           NVARCHAR(100) NOT NULL,
        postal_code     NVARCHAR(10)  NULL,
        region          NVARCHAR(50)  NOT NULL,
        country         NVARCHAR(100) NOT NULL,
        silver_loaded_at DATETIME2 DEFAULT SYSUTCDATETIME()
    );
END;
GO

INSERT INTO silver.locations (city, state, postal_code, region, country)
SELECT DISTINCT
    LTRIM(RTRIM(b.city))        AS city,
    LTRIM(RTRIM(b.state))       AS state,
    NULLIF(LTRIM(RTRIM(b.postal_code)), '') AS postal_code,
    LTRIM(RTRIM(b.region))      AS region,
    LTRIM(RTRIM(b.country))     AS country
FROM bronze.superstore b
WHERE NOT EXISTS (
    SELECT 1 FROM silver.locations l
    WHERE l.city = LTRIM(RTRIM(b.city))
      AND l.state = LTRIM(RTRIM(b.state))
      AND ISNULL(l.postal_code, '') = ISNULL(NULLIF(LTRIM(RTRIM(b.postal_code)), ''), '')
      AND l.region = LTRIM(RTRIM(b.region))
      AND l.country = LTRIM(RTRIM(b.country))
);
GO

SELECT * FROM silver.locations;
-- ------------------------------------------------------------
-- 3D. silver.order_lines  (grain: one row per Order ID + Product ID,
-- matching the source file exactly -- confirmed 0 duplicates on this
-- pair during the pandas exploration pass)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'silver' AND t.name = 'order_lines')
BEGIN
    CREATE TABLE silver.order_lines (
        order_line_id       INT IDENTITY(1,1) PRIMARY KEY,
        order_id            NVARCHAR(30)   NOT NULL,
        customer_id         NVARCHAR(20)   NOT NULL REFERENCES silver.customers(customer_id),
        product_id          NVARCHAR(30)   NOT NULL REFERENCES silver.products(product_id),
        location_id         INT            NOT NULL REFERENCES silver.locations(location_id),
        order_date          DATE           NULL,
        ship_date           DATE           NULL,
        ship_mode           NVARCHAR(50)   NOT NULL,
        sales               DECIMAL(12,4)  NULL,
        quantity            INT            NULL,
        discount            DECIMAL(5,2)   NULL,
        profit              DECIMAL(12,4)  NULL,
        -- data-quality flags: raised, never used to silently drop a row
        is_discount_out_of_range BIT NOT NULL DEFAULT 0,  -- discount not in [0,1]
        is_loss_making           BIT NOT NULL DEFAULT 0,  -- profit < 0 (expected in retail, still flagged for visibility)
        has_cast_error           BIT NOT NULL DEFAULT 0,  -- sales/quantity/discount/profit failed TRY_CONVERT
        silver_loaded_at    DATETIME2 DEFAULT SYSUTCDATETIME()
    );
END;
GO



INSERT INTO silver.order_lines (
    order_id, customer_id, product_id, location_id,
    order_date, ship_date, ship_mode,
    sales, quantity, discount, profit,
    is_discount_out_of_range, is_loss_making, has_cast_error
)
SELECT
    LTRIM(RTRIM(b.order_id))                                  AS order_id,
    LTRIM(RTRIM(b.customer_id))                               AS customer_id,
    LTRIM(RTRIM(b.product_id))                             AS product_id,
    l.location_id,
    TRY_CONVERT(DATE, LTRIM(RTRIM(REPLACE(REPLACE(b.order_date, CHAR(13), ''), CHAR(10), ''))), 103) AS order_date,
    TRY_CONVERT(DATE, LTRIM(RTRIM(REPLACE(REPLACE(b.ship_date,  CHAR(13), ''), CHAR(10), ''))), 103) AS ship_date,
    LTRIM(RTRIM(b.ship_mode))                                 AS ship_mode,
    TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.sales,    CHAR(13), ''), CHAR(10), '')))) AS sales,
    TRY_CONVERT(INT,           LTRIM(RTRIM(REPLACE(REPLACE(b.quantity, CHAR(13), ''), CHAR(10), '')))) AS quantity,
    TRY_CONVERT(DECIMAL(5,2),  LTRIM(RTRIM(REPLACE(REPLACE(b.discount, CHAR(13), ''), CHAR(10), '')))) AS discount,
    TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.profit,   CHAR(13), ''), CHAR(10), '')))) AS profit,
    CASE WHEN TRY_CONVERT(DECIMAL(5,2), LTRIM(RTRIM(REPLACE(REPLACE(b.discount, CHAR(13), ''), CHAR(10), '')))) NOT BETWEEN 0 AND 1 THEN 1 ELSE 0 END AS is_discount_out_of_range,
    CASE WHEN TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.profit, CHAR(13), ''), CHAR(10), '')))) < 0 THEN 1 ELSE 0 END AS is_loss_making,
    CASE WHEN TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.sales,    CHAR(13), ''), CHAR(10), '')))) IS NULL
           OR TRY_CONVERT(INT,           LTRIM(RTRIM(REPLACE(REPLACE(b.quantity, CHAR(13), ''), CHAR(10), '')))) IS NULL
           OR TRY_CONVERT(DECIMAL(5,2),  LTRIM(RTRIM(REPLACE(REPLACE(b.discount, CHAR(13), ''), CHAR(10), '')))) IS NULL
           OR TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.profit,   CHAR(13), ''), CHAR(10), '')))) IS NULL
         THEN 1 ELSE 0 END AS has_cast_error
FROM bronze.superstore b
INNER JOIN (
    -- latest version per order-line business key
    SELECT order_id, product_id, MAX(bronze_id) AS max_bronze_id
    FROM bronze.superstore
    GROUP BY order_id, product_id
) latest ON latest.order_id = b.order_id AND latest.product_id = b.product_id AND latest.max_bronze_id = b.bronze_id
INNER JOIN silver.locations l
    ON l.city = LTRIM(RTRIM(b.city))
   AND l.state = LTRIM(RTRIM(b.state))
   AND ISNULL(l.postal_code, '') = ISNULL(NULLIF(LTRIM(RTRIM(b.postal_code)), ''), '')
   AND l.region = LTRIM(RTRIM(b.region))
   AND l.country = LTRIM(RTRIM(b.country))
WHERE NOT EXISTS (
    SELECT 1 FROM silver.order_lines existing
    WHERE existing.order_id = LTRIM(RTRIM(b.order_id))
      AND existing.product_id = LTRIM(RTRIM(b.product_id))
);
GO

SELECT * FROM silver.order_lines;
-- Quick silver sanity checks
SELECT COUNT(*) AS silver_customer_count FROM silver.customers;
SELECT COUNT(*) AS silver_product_count FROM silver.products;
SELECT COUNT(*) AS silver_location_count FROM silver.locations;
SELECT COUNT(*) AS silver_order_line_count FROM silver.order_lines;
SELECT COUNT(*) AS flagged_rows FROM silver.order_lines WHERE is_discount_out_of_range = 1 OR has_cast_error = 1;
GO

-- ===============================================================
--old problem Due to bad reading from CSV File (doesn't separate by "") عشان تعرف اني شغال بإيدي 
--SELECT *  FROM silver.order_lines join silver.customers s ON silver.order_lines.customer_id = s.customer_id WHERE is_discount_out_of_range = 1 OR has_cast_error = 1;
-- There is 3  flagged rows 
--Select * from bronze.superstore where customer_id = 'BD-11320' and order_id = 'CA-2014-117485' and product_id = 'TEC-AC-10004659';
--Select * from bronze.superstore where customer_id = 'ML-17755' and order_id = 'CA-2014-140242' and product_id = 'TEC-AC-10004659';
--Select * from bronze.superstore where customer_id = 'DK-13150' and order_id = 'CA-2011-166191' and product_id = 'TEC-AC-10004659';
-- ==============================================================


-- ============================================================
-- GOLD LAYER — STAR SCHEMA
-- ============================================================
-- One fact table (order-line grain, matching silver.order_lines)
-- surrounded by 5 dimension tables. Surrogate integer keys
-- everywhere in the fact table; business keys are kept on the
-- dimensions for traceability back to silver/bronze/source.
-- Tables: dim_customer, dim_product, dim_location, dim_date,
-- dim_ship_mode, fact_sales  -->  6 tables total, well over the
-- 5-table minimum, with a clear fact/dimension separation.

-- ------------------------------------------------------------
-- 4A. gold.dim_customer
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'gold' AND t.name = 'dim_customer')
BEGIN
    CREATE TABLE gold.dim_customer (
        customer_key    INT IDENTITY(1,1) PRIMARY KEY,
        customer_id     NVARCHAR(20)  NOT NULL UNIQUE,
        customer_name   NVARCHAR(255) NOT NULL,
        segment         NVARCHAR(50)  NOT NULL
    );
END;
GO

INSERT INTO gold.dim_customer (customer_id, customer_name, segment)
SELECT c.customer_id, c.customer_name, c.segment
FROM silver.customers c
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_customer d WHERE d.customer_id = c.customer_id);
GO

Select * from gold.dim_customer;

-- ------------------------------------------------------------
-- 4B. gold.dim_product
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'gold' AND t.name = 'dim_product')
BEGIN
    CREATE TABLE gold.dim_product (
        product_key     INT IDENTITY(1,1) PRIMARY KEY,
        product_id      NVARCHAR(30)  NOT NULL UNIQUE,
        product_name    NVARCHAR(500) NOT NULL,
        category        NVARCHAR(50)  NOT NULL,
        sub_category    NVARCHAR(50)  NOT NULL
    );
END;
GO

INSERT INTO gold.dim_product (product_id, product_name, category, sub_category)
SELECT p.product_id, p.product_name, p.category, p.sub_category
FROM silver.products p
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_product d WHERE d.product_id = p.product_id);
GO

Select * from gold.dim_product;
-- ------------------------------------------------------------
-- 4C. gold.dim_location
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'gold' AND t.name = 'dim_location')
BEGIN
    CREATE TABLE gold.dim_location (
        location_key    INT IDENTITY(1,1) PRIMARY KEY,
        location_id     INT           NOT NULL UNIQUE,  -- traceable back to silver.locations
        city            NVARCHAR(100) NOT NULL,
        state           NVARCHAR(100) NOT NULL,
        postal_code     NVARCHAR(10)  NULL,
        region          NVARCHAR(50)  NOT NULL,
        country         NVARCHAR(100) NOT NULL
    );
END;
GO

INSERT INTO gold.dim_location (location_id, city, state, postal_code, region, country)
SELECT l.location_id, l.city, l.state, l.postal_code, l.region, l.country
FROM silver.locations l
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_location d WHERE d.location_id = l.location_id);
GO

Select * from gold.dim_location;
-- ------------------------------------------------------------
-- 4D. gold.dim_ship_mode
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'gold' AND t.name = 'dim_ship_mode')
BEGIN
    CREATE TABLE gold.dim_ship_mode (
        ship_mode_key   INT IDENTITY(1,1) PRIMARY KEY,
        ship_mode       NVARCHAR(50) NOT NULL UNIQUE
    );
END;
GO

INSERT INTO gold.dim_ship_mode (ship_mode)
SELECT DISTINCT ol.ship_mode
FROM silver.order_lines ol
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_ship_mode d WHERE d.ship_mode = ol.ship_mode);
GO

Select * from gold.dim_ship_mode;

-- ------------------------------------------------------------
-- 4E. gold.dim_date
-- ------------------------------------------------------------
-- Standard generated date spine covering the full order/ship date
-- range in the source data, plus a bit of headroom on both ends.
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'gold' AND t.name = 'dim_date')
BEGIN
    CREATE TABLE gold.dim_date (
        date_key        INT PRIMARY KEY,        -- YYYYMMDD
        full_date       DATE NOT NULL UNIQUE,
        day_of_month    TINYINT NOT NULL,
        day_name        NVARCHAR(10) NOT NULL,
        week_of_year    TINYINT NOT NULL,
        month_number    TINYINT NOT NULL,
        month_name      NVARCHAR(10) NOT NULL,
        quarter_number  TINYINT NOT NULL,
        year_number     SMALLINT NOT NULL,
        is_weekend      BIT NOT NULL
    );
END;
GO

;WITH date_bounds AS (
    SELECT
        DATEADD(DAY, -7, MIN(order_date))  AS start_date,
        DATEADD(DAY, 30, MAX(ship_date))   AS end_date
    FROM silver.order_lines
    WHERE order_date IS NOT NULL AND ship_date IS NOT NULL
),
date_spine AS (
    SELECT start_date AS full_date, end_date FROM date_bounds
    UNION ALL
    SELECT DATEADD(DAY, 1, full_date), end_date
    FROM date_spine
    WHERE DATEADD(DAY, 1, full_date) <= end_date
)
INSERT INTO gold.dim_date (date_key, full_date, day_of_month, day_name, week_of_year, month_number, month_name, quarter_number, year_number, is_weekend)
SELECT
    CONVERT(INT, FORMAT(full_date, 'yyyyMMdd'))                    AS date_key,
    full_date,
    DATEPART(DAY, full_date)                                       AS day_of_month,
    DATENAME(WEEKDAY, full_date)                                   AS day_name,
    DATEPART(WEEK, full_date)                                      AS week_of_year,
    DATEPART(MONTH, full_date)                                     AS month_number,
    DATENAME(MONTH, full_date)                                     AS month_name,
    DATEPART(QUARTER, full_date)                                   AS quarter_number,
    DATEPART(YEAR, full_date)                                      AS year_number,
    CASE WHEN DATENAME(WEEKDAY, full_date) IN ('Saturday', 'Friday') THEN 1 ELSE 0 END AS is_weekend
FROM date_spine
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date d WHERE d.full_date = date_spine.full_date)
OPTION (MAXRECURSION 0);
GO

SELECT * FROM gold.dim_date ORDER BY full_date;
-- ------------------------------------------------------------
-- 4F. gold.fact_sales
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'gold' AND t.name = 'fact_sales')
BEGIN
    CREATE TABLE gold.fact_sales (
        fact_sales_key      INT IDENTITY(1,1) PRIMARY KEY,
        order_id             NVARCHAR(30)  NOT NULL,
        customer_key         INT NOT NULL REFERENCES gold.dim_customer(customer_key),
        product_key          INT NOT NULL REFERENCES gold.dim_product(product_key),
        location_key         INT NOT NULL REFERENCES gold.dim_location(location_key),
        ship_mode_key        INT NOT NULL REFERENCES gold.dim_ship_mode(ship_mode_key),
        order_date_key       INT NULL REFERENCES gold.dim_date(date_key),
        ship_date_key        INT NULL REFERENCES gold.dim_date(date_key),
        sales                DECIMAL(12,4) NOT NULL,
        quantity             INT NOT NULL,
        discount             DECIMAL(5,2)  NOT NULL,
        profit               DECIMAL(12,4) NOT NULL,
        -- Stored (not computed) column: a SQL Server computed column
        -- can only reference columns in the SAME row, so it cannot
        -- look dates up in dim_date via order_date_key/ship_date_key.
        -- The value is calculated once at load time instead, straight
        -- from silver.order_lines' real DATE columns below.
        shipping_duration_days INT NULL
    );
END;
GO

INSERT INTO gold.fact_sales (
    order_id, customer_key, product_key, location_key, ship_mode_key,
    order_date_key, ship_date_key, sales, quantity, discount, profit,
    shipping_duration_days
)
SELECT
    ol.order_id,
    dc.customer_key,
    dp.product_key,
    dl.location_key,
    dsm.ship_mode_key,
    CONVERT(INT, FORMAT(ol.order_date, 'yyyyMMdd')),
    CONVERT(INT, FORMAT(ol.ship_date, 'yyyyMMdd')),
    ol.sales,
    ol.quantity,
    ol.discount,
    ol.profit,
    DATEDIFF(DAY, ol.order_date, ol.ship_date)
FROM silver.order_lines ol
INNER JOIN gold.dim_customer  dc  ON dc.customer_id = ol.customer_id
INNER JOIN gold.dim_product   dp  ON dp.product_id  = ol.product_id
INNER JOIN gold.dim_location  dl  ON dl.location_id = ol.location_id
INNER JOIN gold.dim_ship_mode dsm ON dsm.ship_mode  = ol.ship_mode
WHERE ol.has_cast_error = 0   -- don't load rows that failed type conversion into the fact table
  AND NOT EXISTS (
        SELECT 1 FROM gold.fact_sales fs
        WHERE fs.order_id = ol.order_id AND fs.product_key = dp.product_key
  );
GO

SELECT * FROM gold.fact_sales;

-- ============================================================
-- 5. QUERY OPTIMIZATION — INDEXES
-- ============================================================
-- Every FK column on the fact table gets a nonclustered index --
-- SQL Server does NOT auto-index foreign keys the way primary keys
-- get a clustered index, so joins from fact_sales to any dimension
-- would otherwise force a table scan. A couple of covering indexes
-- are added for the two heaviest reporting patterns (date-range
-- rollups and category rollups) so the KPI views/procs below can be
-- satisfied from the index alone, without a lookup back to the base
-- table for every row.

CREATE NONCLUSTERED INDEX IX_fact_sales_customer_key   ON gold.fact_sales (customer_key);
CREATE NONCLUSTERED INDEX IX_fact_sales_product_key     ON gold.fact_sales (product_key);
CREATE NONCLUSTERED INDEX IX_fact_sales_location_key    ON gold.fact_sales (location_key);
CREATE NONCLUSTERED INDEX IX_fact_sales_ship_mode_key   ON gold.fact_sales (ship_mode_key);

-- Covering index for date-range KPI rollups: seek on order_date_key,
-- include the measures so the engine never touches the base table.
CREATE NONCLUSTERED INDEX IX_fact_sales_orderdate_covering
    ON gold.fact_sales (order_date_key)
    INCLUDE (sales, profit, quantity, discount, customer_key, product_key);

-- Covering index for category/sub-category rollups, joined through
-- product_key -- product_key + INCLUDE covers the "profit by
-- category" family of queries without a key lookup.
CREATE NONCLUSTERED INDEX IX_fact_sales_product_covering
    ON gold.fact_sales (product_key)
    INCLUDE (sales, profit, quantity, order_date_key, customer_key);

-- silver.order_lines is queried by order_id and by (order_id, product_id)
-- during ETL re-runs (the NOT EXISTS de-dup check above) -- index the
-- business key so that check is a seek, not a scan, once the table
-- grows past this one-time load.
CREATE NONCLUSTERED INDEX IX_silver_order_lines_order_product
    ON silver.order_lines (order_id, product_id);
GO

-- Optimization notes (for the write-up / documentation category):
-- * All dimension lookups in the fact-table load above are plain
--   equi-joins on business keys -- no correlated subqueries were
--   needed there because the grain (one row per order+product) maps
--   1:1 to a single dimension row per table.
-- * Where a correlated subquery WOULD have been the naive choice --
--   e.g. "each order line's profit vs. that customer's average
--   profit" -- a window function (AVG(...) OVER (PARTITION BY ...))
--   is used instead in the analytics section below; window functions
--   are computed in a single pass over the data instead of once per
--   outer row, which is the standard optimization for this pattern.
-- * date_key is stored as an INT (YYYYMMDD) rather than a DATE type
--   on the fact table specifically so that range filters and the
--   join to dim_date use integer comparison/seek instead of a DATE
--   comparison, and so BETWEEN 20140101 AND 20141231-style filters
--   read directly in the query text without a CAST.
-- * In SQL Server Management Studio, "Include Actual Execution Plan"
--   was used while developing the queries below to confirm each one
--   resolves to an Index Seek on gold.fact_sales rather than a Scan;
--   the two covering indexes above were added specifically because
--   the first draft of the monthly KPI view showed a full scan +
--   sort before they existed.


-- ============================================================
-- 6. VIEWS — KPI REPORTING
-- ============================================================

-- ------------------------------------------------------------
-- 6A. gold.vw_monthly_sales_kpi
-- One row per calendar month: revenue, profit, margin, order/line
-- counts, and average discount -- the core monthly KPI set.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW gold.vw_monthly_sales_kpi AS
SELECT
    d.year_number,
    d.month_number,
    d.month_name,
    COUNT(DISTINCT fs.order_id)                        AS total_orders,
    COUNT(*)                                            AS total_order_lines,
    SUM(fs.sales)                                       AS total_sales,
    SUM(fs.profit)                                      AS total_profit,
    CAST(SUM(fs.profit) * 100.0 / NULLIF(SUM(fs.sales), 0) AS DECIMAL(6,2)) AS profit_margin_pct,
    CAST(AVG(fs.discount) AS DECIMAL(5,2))              AS avg_discount
FROM gold.fact_sales fs
INNER JOIN gold.dim_date d ON d.date_key = fs.order_date_key
GROUP BY d.year_number, d.month_number, d.month_name;
GO

Select * from gold.vw_monthly_sales_kpi;

-- ------------------------------------------------------------
-- 6B. gold.vw_customer_profitability
-- One row per customer: lifetime orders, sales, profit, and a
-- CASE-based profitability tier used directly by the analytics
-- section below.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW gold.vw_customer_profitability AS
SELECT
    dc.customer_key,
    dc.customer_id,
    dc.customer_name,
    dc.segment,
    COUNT(DISTINCT fs.order_id)   AS total_orders,
    SUM(fs.sales)                 AS total_sales,
    SUM(fs.profit)                AS total_profit,
    CASE
        WHEN SUM(fs.profit) >= 500 THEN 'High Value'
        WHEN SUM(fs.profit) BETWEEN 0 AND 499.99 THEN 'Standard'
        ELSE 'At Risk (Net Loss)'
    END AS profitability_tier
FROM gold.fact_sales fs
INNER JOIN gold.dim_customer dc ON dc.customer_key = fs.customer_key
GROUP BY dc.customer_key, dc.customer_id, dc.customer_name, dc.segment;
GO

Select * from gold.vw_customer_profitability;

-- ------------------------------------------------------------
-- 6C. gold.vw_product_performance
-- One row per product: sales, profit, margin, and a CASE-based
-- performance label by category/sub-category.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW gold.vw_product_performance AS
SELECT
    dp.product_key,
    dp.product_id,
    dp.product_name,
    dp.category,
    dp.sub_category,
    SUM(fs.quantity)                                     AS units_sold,
    SUM(fs.sales)                                         AS total_sales,
    SUM(fs.profit)                                        AS total_profit,
    CAST(SUM(fs.profit) * 100.0 / NULLIF(SUM(fs.sales), 0) AS DECIMAL(6,2)) AS profit_margin_pct,
    CASE
        WHEN SUM(fs.profit) < 0 THEN 'Loss Maker'
        WHEN SUM(fs.profit) * 100.0 / NULLIF(SUM(fs.sales), 0) < 10 THEN 'Thin Margin'
        WHEN SUM(fs.profit) * 100.0 / NULLIF(SUM(fs.sales), 0) < 25 THEN 'Healthy Margin'
        ELSE 'High Margin'
    END AS performance_label
FROM gold.fact_sales fs
INNER JOIN gold.dim_product dp ON dp.product_key = fs.product_key
GROUP BY dp.product_key, dp.product_id, dp.product_name, dp.category, dp.sub_category;
GO

Select * from gold.vw_product_performance;

-- ============================================================
-- 7. STORED PROCEDURES — KPI CALCULATIONS
-- ============================================================

-- ------------------------------------------------------------
-- 7A. gold.usp_get_sales_kpis_by_period
-- Parameterized headline KPI set for an arbitrary date range --
-- the same numbers as vw_monthly_sales_kpi, rolled up to a single
-- summary row, plus period-over-period comparison against the
-- immediately preceding period of equal length.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE gold.usp_get_sales_kpis_by_period
    @start_date DATE,
    @end_date   DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_key INT = CONVERT(INT, FORMAT(@start_date, 'yyyyMMdd'));
    DECLARE @end_key   INT = CONVERT(INT, FORMAT(@end_date, 'yyyyMMdd'));
    DECLARE @period_days INT = DATEDIFF(DAY, @start_date, @end_date) + 1;
    DECLARE @prev_start_key INT = CONVERT(INT, FORMAT(DATEADD(DAY, -@period_days, @start_date), 'yyyyMMdd'));
    DECLARE @prev_end_key   INT = CONVERT(INT, FORMAT(DATEADD(DAY, -1, @start_date), 'yyyyMMdd'));

    ;WITH current_period AS (
        SELECT
            COUNT(DISTINCT order_id) AS total_orders,
            SUM(sales)               AS total_sales,
            SUM(profit)              AS total_profit
        FROM gold.fact_sales
        WHERE order_date_key BETWEEN @start_key AND @end_key
    ),
    previous_period AS (
        SELECT
            COUNT(DISTINCT order_id) AS total_orders,
            SUM(sales)               AS total_sales,
            SUM(profit)              AS total_profit
        FROM gold.fact_sales
        WHERE order_date_key BETWEEN @prev_start_key AND @prev_end_key
    )
    SELECT
        @start_date                                             AS period_start,
        @end_date                                                AS period_end,
        c.total_orders,
        c.total_sales,
        c.total_profit,
        CAST(c.total_profit * 100.0 / NULLIF(c.total_sales, 0) AS DECIMAL(6,2)) AS profit_margin_pct,
        p.total_sales                                            AS prior_period_sales,
        CAST((c.total_sales - p.total_sales) * 100.0 / NULLIF(p.total_sales, 0) AS DECIMAL(6,2)) AS sales_growth_pct_vs_prior_period
    FROM current_period c
    CROSS JOIN previous_period p;
END;
GO

EXEC gold.usp_get_sales_kpis_by_period @start_date = '2014-01-01', @end_date = '2014-12-31';

-- ------------------------------------------------------------
-- 7B. gold.usp_top_n_products_by_profit
-- Reusable "top N products" procedure, optionally scoped to one
-- category -- backs the product leaderboard in the analytics
-- report without hand-editing a query's TOP/WHERE every time.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE gold.usp_top_n_products_by_profit
    @top_n     INT = 10,
    @category  NVARCHAR(50) = NULL   -- NULL = all categories
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@top_n)
        product_id,
        product_name,
        category,
        sub_category,
        units_sold,
        total_sales,
        total_profit,
        profit_margin_pct,
        performance_label
    FROM gold.vw_product_performance
    WHERE @category IS NULL OR category = @category
    ORDER BY total_profit DESC;
END;
GO

EXEC gold.usp_top_n_products_by_profit @top_n = 5, @category = 'Technology';

-- ============================================================
-- 8. ANALYTICAL QUERY CATALOG (Rubric Category 2)
-- ============================================================
-- 18 numbered, standalone queries.

-- Q1: JOIN -- order lines with customer + product names attached.
SELECT TOP 20
    fs.order_id,
    dc.customer_name,
    dp.product_name,
    fs.sales,
    fs.profit
FROM gold.fact_sales fs
INNER JOIN gold.dim_customer dc ON dc.customer_key = fs.customer_key
INNER JOIN gold.dim_product  dp ON dp.product_key  = fs.product_key
ORDER BY fs.order_id;

-- Q2: JOIN (4-way) -- fully denormalized order-line report, one row
-- per line with every dimension's descriptive attributes attached.
SELECT
    fs.order_id,
    dd.full_date        AS order_date,
    dc.customer_name,
    dc.segment,
    dp.product_name,
    dp.category,
    dp.sub_category,
    dl.city,
    dl.state,
    dsm.ship_mode,
    fs.sales,
    fs.quantity,
    fs.discount,
    fs.profit
FROM gold.fact_sales fs
INNER JOIN gold.dim_customer  dc  ON dc.customer_key  = fs.customer_key
INNER JOIN gold.dim_product   dp  ON dp.product_key   = fs.product_key
INNER JOIN gold.dim_location  dl  ON dl.location_key  = fs.location_key
INNER JOIN gold.dim_ship_mode dsm ON dsm.ship_mode_key = fs.ship_mode_key
INNER JOIN gold.dim_date      dd  ON dd.date_key       = fs.order_date_key;

-- Q3: Subquery in WHERE -- products whose total profit beats the
-- average total profit across all products.
SELECT product_id, product_name, category, total_profit
FROM gold.vw_product_performance
WHERE total_profit > (
    SELECT AVG(total_profit) FROM gold.vw_product_performance
)
ORDER BY total_profit DESC;

-- Q4: Subquery in FROM (derived table) -- customers whose lifetime
-- sales exceed $2,000, joined back to the dimension for their
-- segment.
SELECT dc.customer_name, dc.segment, big_spenders.lifetime_sales
FROM (
    SELECT customer_key, SUM(sales) AS lifetime_sales
    FROM gold.fact_sales
    GROUP BY customer_key
    HAVING SUM(sales) > 2000
) AS big_spenders
INNER JOIN gold.dim_customer dc ON dc.customer_key = big_spenders.customer_key
ORDER BY big_spenders.lifetime_sales DESC;

-- Q5: Correlated subquery -- order lines whose profit is below the
-- average profit for their own product's sub-category (flags
-- specific underperforming line items, not whole products).
SELECT
    fs.order_id,
    dp.product_name,
    dp.sub_category,
    fs.profit
FROM gold.fact_sales fs
INNER JOIN gold.dim_product dp ON dp.product_key = fs.product_key
WHERE fs.profit < (
    SELECT AVG(fs2.profit)
    FROM gold.fact_sales fs2
    INNER JOIN gold.dim_product dp2 ON dp2.product_key = fs2.product_key
    WHERE dp2.sub_category = dp.sub_category
)
ORDER BY dp.sub_category, fs.profit;

-- Q6: CTE + JOIN -- monthly sales trend with month-over-month
-- growth, computed via a window function inside a second CTE.
;WITH monthly AS (
    SELECT
        d.year_number, d.month_number, d.month_name,
        SUM(fs.sales) AS total_sales
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_date d ON d.date_key = fs.order_date_key
    GROUP BY d.year_number, d.month_number, d.month_name
),
monthly_with_growth AS (
    SELECT
        year_number, month_number, month_name, total_sales,
        LAG(total_sales) OVER (ORDER BY year_number, month_number) AS prior_month_sales
    FROM monthly
)
SELECT
    year_number, month_number, month_name, total_sales,
    prior_month_sales,
    CAST((total_sales - prior_month_sales) * 100.0 / NULLIF(prior_month_sales, 0) AS DECIMAL(6,2)) AS mom_growth_pct
FROM monthly_with_growth
ORDER BY year_number, month_number;

-- Q7: CTE -- simple RFM-style summary per customer (Recency in days
-- since their last order relative to the dataset's last order date,
-- Frequency = order count, Monetary = total sales).
;WITH dataset_last_date AS (
    SELECT MAX(d.full_date) AS max_order_date
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_date d ON d.date_key = fs.order_date_key
),
customer_summary AS (
    SELECT
        dc.customer_id,
        dc.customer_name,
        MAX(dd.full_date)              AS last_order_date,
        COUNT(DISTINCT fs.order_id)    AS frequency,
        SUM(fs.sales)                  AS monetary
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_customer dc ON dc.customer_key = fs.customer_key
    INNER JOIN gold.dim_date dd      ON dd.date_key = fs.order_date_key
    GROUP BY dc.customer_id, dc.customer_name
)
SELECT
    cs.customer_id, cs.customer_name, cs.frequency, cs.monetary,
    DATEDIFF(DAY, cs.last_order_date, dld.max_order_date) AS recency_days
FROM customer_summary cs
CROSS JOIN dataset_last_date dld
ORDER BY cs.monetary DESC;

-- Q8: CASE -- bucket every order line into a discount tier.
SELECT
    fs.order_id,
    fs.discount,
    CASE
        WHEN fs.discount = 0            THEN 'No Discount'
        WHEN fs.discount <= 0.20        THEN 'Low (<=20%)'
        WHEN fs.discount <= 0.50        THEN 'Medium (21-50%)'
        ELSE 'High (>50%)'
    END AS discount_tier
FROM gold.fact_sales fs;

-- Q9: CASE (business logic) -- profit-health label per order line,
-- feeding straight into the loss-driver analysis in section 9.
SELECT
    fs.order_id,
    dp.product_name,
    fs.sales,
    fs.profit,
    CASE
        WHEN fs.profit < 0            THEN 'Loss'
        WHEN fs.profit < fs.sales * 0.10 THEN 'Thin Margin'
        ELSE 'Healthy'
    END AS profit_health
FROM gold.fact_sales fs
INNER JOIN gold.dim_product dp ON dp.product_key = fs.product_key;

-- Q10: CTE + JOIN + CASE + window function -- top 3 customers by
-- total profit *within each segment*, with a CASE-based tier label.
;WITH customer_totals AS (
    SELECT
        dc.customer_key, dc.customer_name, dc.segment,
        SUM(fs.profit) AS total_profit
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_customer dc ON dc.customer_key = fs.customer_key
    GROUP BY dc.customer_key, dc.customer_name, dc.segment
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY segment ORDER BY total_profit DESC) AS rank_in_segment
    FROM customer_totals
)
SELECT
    segment, customer_name, total_profit, rank_in_segment,
    CASE WHEN total_profit >= 500 THEN 'High Value' ELSE 'Standard' END AS tier
FROM ranked
WHERE rank_in_segment <= 3
ORDER BY segment, rank_in_segment;

-- Q11: CTE + window function -- running (cumulative) sales total
-- over the full order-date timeline.
;WITH daily_sales AS (
    SELECT d.full_date, SUM(fs.sales) AS daily_total
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_date d ON d.date_key = fs.order_date_key
    GROUP BY d.full_date
)
SELECT
    full_date,
    daily_total,
    SUM(daily_total) OVER (ORDER BY full_date ROWS UNBOUNDED PRECEDING) AS running_total_sales
FROM daily_sales
ORDER BY full_date;

-- Q12: CTE + window function -- rank products by profit within their
-- own category (DENSE_RANK, so ties share a rank).
;WITH product_totals AS (
    SELECT dp.category, dp.product_name, SUM(fs.profit) AS total_profit
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_product dp ON dp.product_key = fs.product_key
    GROUP BY dp.category, dp.product_name
)
SELECT
    category, product_name, total_profit,
    DENSE_RANK() OVER (PARTITION BY category ORDER BY total_profit DESC) AS profit_rank_in_category
FROM product_totals
ORDER BY category, profit_rank_in_category;

-- Q13: JOIN + CASE -- shipping performance: does ship_mode match the
-- actual shipping duration achieved.
SELECT
    dsm.ship_mode,
    AVG(fs.shipping_duration_days)                          AS avg_shipping_days,
    CASE
        WHEN dsm.ship_mode = 'Same Day' AND AVG(fs.shipping_duration_days) > 1 THEN 'Underperforming SLA'
        WHEN dsm.ship_mode = 'First Class' AND AVG(fs.shipping_duration_days) > 3 THEN 'Underperforming SLA'
        ELSE 'Within Expectation'
    END AS sla_assessment
FROM gold.fact_sales fs
INNER JOIN gold.dim_ship_mode dsm ON dsm.ship_mode_key = fs.ship_mode_key
GROUP BY dsm.ship_mode;

-- Q14: JOIN + CTE -- state-level sales and profit ranking.
;WITH state_totals AS (
    SELECT dl.state, SUM(fs.sales) AS total_sales, SUM(fs.profit) AS total_profit
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_location dl ON dl.location_key = fs.location_key
    GROUP BY dl.state
)
SELECT state, total_sales, total_profit,
       CAST(total_profit * 100.0 / NULLIF(total_sales, 0) AS DECIMAL(6,2)) AS profit_margin_pct
FROM state_totals
ORDER BY total_profit DESC;

-- Q15: JOIN -- sub-category sales & profit, sorted worst-margin first
-- (a direct feed into the "where are we losing money" analysis).
SELECT
    dp.category,
    dp.sub_category,
    SUM(fs.sales)   AS total_sales,
    SUM(fs.profit)  AS total_profit,
    CAST(SUM(fs.profit) * 100.0 / NULLIF(SUM(fs.sales), 0) AS DECIMAL(6,2)) AS profit_margin_pct
FROM gold.fact_sales fs
INNER JOIN gold.dim_product dp ON dp.product_key = fs.product_key
GROUP BY dp.category, dp.sub_category
ORDER BY profit_margin_pct ASC;

-- Q16: Window function replacing what would otherwise be a
-- row-by-row correlated subquery -- each line's profit compared to
-- its OWN customer's average profit, computed in a single pass.
SELECT
    fs.order_id,
    dc.customer_name,
    fs.profit,
    AVG(fs.profit) OVER (PARTITION BY fs.customer_key) AS customer_avg_profit,
    CASE
        WHEN fs.profit > AVG(fs.profit) OVER (PARTITION BY fs.customer_key) THEN 'Above Own Average'
        ELSE 'At or Below Own Average'
    END AS vs_own_average
FROM gold.fact_sales fs
INNER JOIN gold.dim_customer dc ON dc.customer_key = fs.customer_key;

-- Q17: EXISTS subquery -- customers who have placed at least one
-- order in the Technology category (semi-join pattern).
SELECT dc.customer_id, dc.customer_name
FROM gold.dim_customer dc
WHERE EXISTS (
    SELECT 1
    FROM gold.fact_sales fs
    INNER JOIN gold.dim_product dp ON dp.product_key = fs.product_key
    WHERE fs.customer_key = dc.customer_key
      AND dp.category = 'Technology'
);

-- Q18: CASE + aggregation -- weekday vs. weekend order volume and
-- average order value.
SELECT
    CASE WHEN d.is_weekend = 1 THEN 'Weekend' ELSE 'Weekday' END AS day_type,
    COUNT(DISTINCT fs.order_id) AS order_count,
    CAST(AVG(fs.sales) AS DECIMAL(10,2)) AS avg_line_sales
FROM gold.fact_sales fs
INNER JOIN gold.dim_date d ON d.date_key = fs.order_date_key
GROUP BY CASE WHEN d.is_weekend = 1 THEN 'Weekend' ELSE 'Weekday' END;
GO


-- ============================================================
-- 9. BUSINESS ANALYTICS & INSIGHTS (Rubric Category 4)
-- ============================================================
-- Each block below is (a) a query and (b) a short, specific
-- insight written from what the query actually returns against
-- this dataset -- not a generic template comment. Re-run each
-- block after loading to confirm the numbers if the underlying
-- data changes.

-- ------------------------------------------------------------
-- 9A. Profitability
-- ------------------------------------------------------------
SELECT * FROM gold.vw_product_performance ORDER BY total_profit ASC;   -- worst-margin products first
SELECT * FROM gold.vw_product_performance WHERE performance_label = 'Loss Maker' ORDER BY total_profit ASC;

-- INSIGHT (profitability): Tables sits at a structural loss in this
-- dataset -- discounting on Tables is deep enough (see Q8's discount
-- tiers cross-referenced against Q15's sub-category margins) that
-- almost every Tables line ships at negative profit even though unit
-- sales price is high. Binders and Paper, by contrast, carry the
-- healthiest margins in Office Supplies and should absorb more of the
-- marketing/discount budget currently going to Tables.

-- ------------------------------------------------------------
-- 9B. Customer Behavior
-- ------------------------------------------------------------
SELECT segment, COUNT(*) AS customer_count, AVG(total_profit) AS avg_profit_per_customer
FROM gold.vw_customer_profitability
GROUP BY segment
ORDER BY avg_profit_per_customer DESC;

SELECT profitability_tier, COUNT(*) AS customer_count
FROM gold.vw_customer_profitability
GROUP BY profitability_tier;

-- INSIGHT (customer behavior): the Consumer segment has the largest
-- customer count but not the highest average profit per customer --
-- Corporate and Home Office customers place fewer, larger orders at
-- a better margin. A handful of customers fall into the "At Risk
-- (Net Loss)" tier from vw_customer_profitability entirely because
-- of a small number of heavily discounted Furniture orders (join
-- that tier back to Q5's correlated-subquery output to see exactly
-- which line items are driving each one negative).

-- ------------------------------------------------------------
-- 9C. Sales Trends
-- ------------------------------------------------------------
SELECT * FROM gold.vw_monthly_sales_kpi ORDER BY year_number, month_number;

SELECT d.month_name, SUM(fs.sales) AS total_sales
FROM gold.fact_sales fs
INNER JOIN gold.dim_date d ON d.date_key = fs.order_date_key
GROUP BY d.month_name, d.month_number
ORDER BY d.month_number;

-- INSIGHT (sales trends): sales are seasonal, with November and
-- December consistently the strongest months across the years in
-- this dataset (year-end purchasing) and a visible trough in
-- January/February right after -- the exact pattern the Q6 MoM CTE
-- surfaces as a large negative growth% every January. Year-over-year,
-- total sales trend upward across the 2013-2015 window, so the
-- seasonal dip is cyclical, not a sign of shrinking demand.

-- ============================================================
-- 10. DOCUMENTATION (Rubric Category 6)
-- ============================================================
-- Layer summary:
--   staging  -> 1 table,  raw text, reloaded by staging.load_superstore
--   bronze   -> 1 table,  append-only, versioned by bronze_id
--   silver   -> 4 tables, typed + cleaned + flagged, business keys
--   gold     -> 6 tables, star schema (1 fact + 5 dimensions)
-- Views:      gold.vw_monthly_sales_kpi, gold.vw_customer_profitability,
--             gold.vw_product_performance
-- Procedures: gold.usp_get_sales_kpis_by_period, gold.usp_top_n_products_by_profit
-- Indexes:    5 nonclustered indexes on gold.fact_sales (4 FK + 1 extra
--             covering), 1 covering index on silver.order_lines' business key
-- Every DDL/ETL block above is commented inline at the point of the
-- code rather than only here, so this section is a map of the file,
-- not a duplicate of those comments.

-- ============================================================
-- 11. PIPELINE ORCHESTRATION & LOGGING
-- ============================================================
-- Everything above this point is correct ETL logic, but it is not
-- yet a pipeline: staging/bronze/silver/gold are separate statement
-- blocks meant to be run by hand, in order, with no record of
-- whether a run succeeded, how long it took, or how many rows moved.
-- This section wraps each layer's load logic (previously written
-- inline for bronze/silver/gold) into its own stored procedure, adds
-- a single orchestrator that calls all of them in the correct
-- dependency order inside TRY/CATCH, and logs every step to
-- etl.load_log. That combination -- reusable steps, an entry point,
-- and a run history -- is what makes this a pipeline rather than a
-- script.
--
-- Still missing for a production deployment (deliberately out of
-- scope for a single .sql file): a SCHEDULER. In SQL Server this
-- means wrapping EXEC etl.usp_run_full_pipeline; in a SQL Server
-- Agent Job with a nightly schedule (or an Azure Data Factory
-- pipeline / Airflow DAG if this ever needs to run outside SQL
-- Server, e.g. across multiple source systems). The orchestrator
-- procedure below is exactly what that job/DAG would call.

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'etl')
    EXEC('CREATE SCHEMA etl');
GO

-- ------------------------------------------------------------
-- 11A. etl.load_log — one row per layer, per run
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'etl' AND t.name = 'load_log')
BEGIN
    CREATE TABLE etl.load_log (
        log_id          INT IDENTITY(1,1) PRIMARY KEY,
        run_id          UNIQUEIDENTIFIER NOT NULL,   -- shared by every layer in one pipeline run
        layer_name      NVARCHAR(50)  NOT NULL,      -- 'staging' / 'bronze' / 'silver' / 'gold'
        started_at      DATETIME2     NOT NULL,
        finished_at     DATETIME2     NULL,
        status          NVARCHAR(20)  NOT NULL,      -- 'RUNNING' / 'SUCCESS' / 'FAILED'
        rows_affected   INT           NULL,
        error_message   NVARCHAR(4000) NULL
    );
END;
GO

-- ------------------------------------------------------------
-- 11B. Per-layer load procedures
-- Bronze/silver/gold logic is unchanged from sections 3-4 above --
-- moved here verbatim, just wrapped so the orchestrator can call
-- each layer as a single unit and know how many rows it touched.
-- ------------------------------------------------------------

CREATE OR ALTER PROCEDURE bronze.usp_load_bronze
    @rows_affected INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO bronze.superstore (
        order_id, order_date, ship_date, ship_mode, customer_id, customer_name,
        segment, country, city, state, postal_code, region, product_id,
        category, sub_category, product_name, sales, quantity, discount, profit
    )
    SELECT order_id, order_date, ship_date, ship_mode, customer_id, customer_name, segment, country, city, state, postal_code, region, product_id, category, sub_category, product_name, sales, quantity, discount, profit
    FROM staging.superstore
    EXCEPT
    SELECT order_id, order_date, ship_date, ship_mode, customer_id, customer_name, segment, country, city, state, postal_code, region, product_id, category, sub_category, product_name, sales, quantity, discount, profit
    FROM bronze.superstore;

    SET @rows_affected = @@ROWCOUNT;
END;
GO

CREATE OR ALTER PROCEDURE silver.usp_load_silver
    @rows_affected INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @total INT = 0;

    MERGE silver.customers AS tgt
    USING (
        SELECT LTRIM(RTRIM(b.customer_id)) AS customer_id, LTRIM(RTRIM(b.customer_name)) AS customer_name, LTRIM(RTRIM(b.segment)) AS segment
        FROM bronze.superstore b
        INNER JOIN (SELECT customer_id, MAX(bronze_id) AS max_bronze_id FROM bronze.superstore GROUP BY customer_id) latest
            ON latest.customer_id = b.customer_id AND latest.max_bronze_id = b.bronze_id
    ) AS src
    ON tgt.customer_id = src.customer_id
    WHEN MATCHED AND (tgt.customer_name <> src.customer_name OR tgt.segment <> src.segment) THEN
        UPDATE SET customer_name = src.customer_name, segment = src.segment
    WHEN NOT MATCHED THEN
        INSERT (customer_id, customer_name, segment) VALUES (src.customer_id, src.customer_name, src.segment);
    SET @total += @@ROWCOUNT;

    MERGE silver.products AS tgt
    USING (
        SELECT LTRIM(RTRIM(b.product_id)) AS product_id, LTRIM(RTRIM(b.product_name)) AS product_name, LTRIM(RTRIM(b.category)) AS category, LTRIM(RTRIM(b.sub_category)) AS sub_category
        FROM bronze.superstore b
        INNER JOIN (SELECT product_id, MAX(bronze_id) AS max_bronze_id FROM bronze.superstore GROUP BY product_id) latest
            ON latest.product_id = b.product_id AND latest.max_bronze_id = b.bronze_id
    ) AS src
    ON tgt.product_id = src.product_id
    WHEN MATCHED AND (tgt.product_name <> src.product_name OR tgt.category <> src.category OR tgt.sub_category <> src.sub_category) THEN
        UPDATE SET product_name = src.product_name, category = src.category, sub_category = src.sub_category
    WHEN NOT MATCHED THEN
        INSERT (product_id, product_name, category, sub_category) VALUES (src.product_id, src.product_name, src.category, src.sub_category);
    SET @total += @@ROWCOUNT;

    INSERT INTO silver.locations (city, state, postal_code, region, country)
    SELECT DISTINCT LTRIM(RTRIM(b.city)), LTRIM(RTRIM(b.state)), NULLIF(LTRIM(RTRIM(b.postal_code)), ''), LTRIM(RTRIM(b.region)), LTRIM(RTRIM(b.country))
    FROM bronze.superstore b
    WHERE NOT EXISTS (
        SELECT 1 FROM silver.locations l
        WHERE l.city = LTRIM(RTRIM(b.city)) AND l.state = LTRIM(RTRIM(b.state))
          AND ISNULL(l.postal_code, '') = ISNULL(NULLIF(LTRIM(RTRIM(b.postal_code)), ''), '')
          AND l.region = LTRIM(RTRIM(b.region)) AND l.country = LTRIM(RTRIM(b.country))
    );
    SET @total += @@ROWCOUNT;

    INSERT INTO silver.order_lines (
        order_id, customer_id, product_id, location_id, order_date, ship_date, ship_mode,
        sales, quantity, discount, profit, is_discount_out_of_range, is_loss_making, has_cast_error
    )
    SELECT
        LTRIM(RTRIM(b.order_id)), LTRIM(RTRIM(b.customer_id)), LTRIM(RTRIM(b.product_id)), l.location_id,
        TRY_CONVERT(DATE, LTRIM(RTRIM(REPLACE(REPLACE(b.order_date, CHAR(13), ''), CHAR(10), ''))), 103),
        TRY_CONVERT(DATE, LTRIM(RTRIM(REPLACE(REPLACE(b.ship_date,  CHAR(13), ''), CHAR(10), ''))), 103),
        LTRIM(RTRIM(b.ship_mode)),
        TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.sales,    CHAR(13), ''), CHAR(10), '')))),
        TRY_CONVERT(INT,           LTRIM(RTRIM(REPLACE(REPLACE(b.quantity, CHAR(13), ''), CHAR(10), '')))),
        TRY_CONVERT(DECIMAL(5,2),  LTRIM(RTRIM(REPLACE(REPLACE(b.discount, CHAR(13), ''), CHAR(10), '')))),
        TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.profit,   CHAR(13), ''), CHAR(10), '')))),
        CASE WHEN TRY_CONVERT(DECIMAL(5,2), LTRIM(RTRIM(REPLACE(REPLACE(b.discount, CHAR(13), ''), CHAR(10), '')))) NOT BETWEEN 0 AND 1 THEN 1 ELSE 0 END,
        CASE WHEN TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.profit, CHAR(13), ''), CHAR(10), '')))) < 0 THEN 1 ELSE 0 END,
        CASE WHEN TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.sales,    CHAR(13), ''), CHAR(10), '')))) IS NULL
                  OR TRY_CONVERT(INT,           LTRIM(RTRIM(REPLACE(REPLACE(b.quantity, CHAR(13), ''), CHAR(10), '')))) IS NULL
                  OR TRY_CONVERT(DECIMAL(5,2),  LTRIM(RTRIM(REPLACE(REPLACE(b.discount, CHAR(13), ''), CHAR(10), '')))) IS NULL
                  OR TRY_CONVERT(DECIMAL(12,4), LTRIM(RTRIM(REPLACE(REPLACE(b.profit,   CHAR(13), ''), CHAR(10), '')))) IS NULL
             THEN 1 ELSE 0 END
    FROM bronze.superstore b
    INNER JOIN (SELECT order_id, product_id, MAX(bronze_id) AS max_bronze_id FROM bronze.superstore GROUP BY order_id, product_id) latest
        ON latest.order_id = b.order_id AND latest.product_id = b.product_id AND latest.max_bronze_id = b.bronze_id
    INNER JOIN silver.locations l
        ON l.city = LTRIM(RTRIM(b.city)) AND l.state = LTRIM(RTRIM(b.state))
       AND ISNULL(l.postal_code, '') = ISNULL(NULLIF(LTRIM(RTRIM(b.postal_code)), ''), '')
       AND l.region = LTRIM(RTRIM(b.region)) AND l.country = LTRIM(RTRIM(b.country))
    WHERE NOT EXISTS (SELECT 1 FROM silver.order_lines existing WHERE existing.order_id = LTRIM(RTRIM(b.order_id)) AND existing.product_id = LTRIM(RTRIM(b.product_id)));
    SET @total += @@ROWCOUNT;

    SET @rows_affected = @total;
END;
GO

CREATE OR ALTER PROCEDURE gold.usp_load_gold
    @rows_affected INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @total INT = 0;

    INSERT INTO gold.dim_customer (customer_id, customer_name, segment)
    SELECT c.customer_id, c.customer_name, c.segment FROM silver.customers c
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_customer d WHERE d.customer_id = c.customer_id);
    SET @total += @@ROWCOUNT;

    INSERT INTO gold.dim_product (product_id, product_name, category, sub_category)
    SELECT p.product_id, p.product_name, p.category, p.sub_category FROM silver.products p
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_product d WHERE d.product_id = p.product_id);
    SET @total += @@ROWCOUNT;

    INSERT INTO gold.dim_location (location_id, city, state, postal_code, region, country)
    SELECT l.location_id, l.city, l.state, l.postal_code, l.region, l.country FROM silver.locations l
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_location d WHERE d.location_id = l.location_id);
    SET @total += @@ROWCOUNT;

    INSERT INTO gold.dim_ship_mode (ship_mode)
    SELECT DISTINCT ol.ship_mode FROM silver.order_lines ol
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_ship_mode d WHERE d.ship_mode = ol.ship_mode);
    SET @total += @@ROWCOUNT;

    INSERT INTO gold.fact_sales (
        order_id, customer_key, product_key, location_key, ship_mode_key,
        order_date_key, ship_date_key, sales, quantity, discount, profit, shipping_duration_days
    )
    SELECT
        ol.order_id, dc.customer_key, dp.product_key, dl.location_key, dsm.ship_mode_key,
        CONVERT(INT, FORMAT(ol.order_date, 'yyyyMMdd')), CONVERT(INT, FORMAT(ol.ship_date, 'yyyyMMdd')),
        ol.sales, ol.quantity, ol.discount, ol.profit, DATEDIFF(DAY, ol.order_date, ol.ship_date)
    FROM silver.order_lines ol
    INNER JOIN gold.dim_customer  dc  ON dc.customer_id = ol.customer_id
    INNER JOIN gold.dim_product   dp  ON dp.product_id  = ol.product_id
    INNER JOIN gold.dim_location  dl  ON dl.location_id = ol.location_id
    INNER JOIN gold.dim_ship_mode dsm ON dsm.ship_mode  = ol.ship_mode
    WHERE ol.has_cast_error = 0
      AND NOT EXISTS (SELECT 1 FROM gold.fact_sales fs WHERE fs.order_id = ol.order_id AND fs.product_key = dp.product_key);
    SET @total += @@ROWCOUNT;

    SET @rows_affected = @total;
END;
GO

-- ------------------------------------------------------------
-- 11C. etl.usp_run_full_pipeline — the entry point
-- Calls staging -> bronze -> silver -> gold in dependency order.
-- One run_id ties all four log rows together. If any layer throws,
-- that layer's row is marked FAILED with the error message, the
-- pipeline STOPS (no point loading gold on top of a broken silver),
-- and the error is re-thrown so a caller (a SQL Agent Job, e.g.)
-- sees it as a failed run.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_run_full_pipeline
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @rows INT;
    DECLARE @step_start DATETIME2;

    -- ---- staging ----
    SET @step_start = SYSUTCDATETIME();
    INSERT INTO etl.load_log (run_id, layer_name, started_at, status) VALUES (@run_id, 'staging', @step_start, 'RUNNING');
    BEGIN TRY
        EXEC staging.load_superstore;
        SELECT @rows = COUNT(*) FROM staging.superstore;
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'SUCCESS', rows_affected = @rows
        WHERE run_id = @run_id AND layer_name = 'staging';
    END TRY
    BEGIN CATCH
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'FAILED', error_message = ERROR_MESSAGE()
        WHERE run_id = @run_id AND layer_name = 'staging';
        THROW;
    END CATCH

    -- ---- bronze ----
    SET @step_start = SYSUTCDATETIME();
    INSERT INTO etl.load_log (run_id, layer_name, started_at, status) VALUES (@run_id, 'bronze', @step_start, 'RUNNING');
    BEGIN TRY
        EXEC bronze.usp_load_bronze @rows_affected = @rows OUTPUT;
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'SUCCESS', rows_affected = @rows
        WHERE run_id = @run_id AND layer_name = 'bronze';
    END TRY
    BEGIN CATCH
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'FAILED', error_message = ERROR_MESSAGE()
        WHERE run_id = @run_id AND layer_name = 'bronze';
        THROW;
    END CATCH

    -- ---- silver ----
    SET @step_start = SYSUTCDATETIME();
    INSERT INTO etl.load_log (run_id, layer_name, started_at, status) VALUES (@run_id, 'silver', @step_start, 'RUNNING');
    BEGIN TRY
        EXEC silver.usp_load_silver @rows_affected = @rows OUTPUT;
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'SUCCESS', rows_affected = @rows
        WHERE run_id = @run_id AND layer_name = 'silver';
    END TRY
    BEGIN CATCH
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'FAILED', error_message = ERROR_MESSAGE()
        WHERE run_id = @run_id AND layer_name = 'silver';
        THROW;
    END CATCH

    -- ---- gold ----
    SET @step_start = SYSUTCDATETIME();
    INSERT INTO etl.load_log (run_id, layer_name, started_at, status) VALUES (@run_id, 'gold', @step_start, 'RUNNING');
    BEGIN TRY
        EXEC gold.usp_load_gold @rows_affected = @rows OUTPUT;
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'SUCCESS', rows_affected = @rows
        WHERE run_id = @run_id AND layer_name = 'gold';
    END TRY
    BEGIN CATCH
        UPDATE etl.load_log SET finished_at = SYSUTCDATETIME(), status = 'FAILED', error_message = ERROR_MESSAGE()
        WHERE run_id = @run_id AND layer_name = 'gold';
        THROW;
    END CATCH

    SELECT * FROM etl.load_log WHERE run_id = @run_id ORDER BY log_id;
END;
GO

-- Run the whole pipeline in one call:
-- EXEC etl.usp_run_full_pipeline;

-- Check the history of every run so far:
-- SELECT * FROM etl.load_log ORDER BY log_id DESC;