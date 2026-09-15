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

-- ============================================================
-- SILVER LAYER
-- ============================================================
-- 5 tables (customer_profiles and product_inventory are absorbed
-- into customers/products here -- this is where integration happens).
-- Per table: take the latest bronze version per business key, TRY_CAST
-- every column to its real type, clean (trim/blank->NULL), flag
-- missing/invalid/outlier values (flagged, never dropped or nulled),
-- then MERGE upsert on the business key so silver always holds exactly
-- one current row per entity.
