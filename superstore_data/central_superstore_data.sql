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
-- STEP 2 — SQL SERVER STAGING TABLE
-- Raw data lands here exactly as received from Excel: no type
-- enforcement beyond what's needed to load it, no cleaning yet.
-- (Written in SQLite syntax for the working prototype; the
--  T-SQL/SQL Server equivalent is noted alongside each type.)
-- ============================================================
 
DROP TABLE IF EXISTS staging.superstore;
 
CREATE TABLE staging.superstore (
    row_id          INT,
    order_id        VARCHAR(255),
    order_date      VARCHAR(255), 
    ship_date       VARCHAR(255), 
    ship_mode       VARCHAR(255),  
    customer_id     VARCHAR(255),
    customer_name   VARCHAR(255), 
    segment         VARCHAR(255),    
    country         VARCHAR(255),   
    city            VARCHAR(255),   
    state           VARCHAR(255),   
    postal_code     VARCHAR(255),  
    region          VARCHAR(255),   
    product_id      VARCHAR(255),   
    category        VARCHAR(255),   
    sub_category    VARCHAR(255),  
    product_name    VARCHAR(255),  
    sales            VARCHAR(255),  
    quantity         VARCHAR(255),
    discount         VARCHAR(255),
    profit           VARCHAR(255)
);
 
-- Loaded by load_staging.py (bulk row-by-row insert from the
-- Excel source). In production SQL Server this step would be a
-- BULK INSERT / OPENROWSET / SSIS load from the source file into
-- this same unvalidated shape.
--------------------------------------------------------------------
-- Truncate + reload every staging table from its current batch file.

TRUNCATE TABLE staging.superstore;

BULK INSERT staging.superstore
FROM 'D:\mido\depi\MSSQL16.SQLEXPRESS\Mini-Project\Central_Superstore.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ';',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'D:\mido\depi\MSSQL16.SQLEXPRESS\Mini-Project\superstore_err.log',
    TABLOCK
);
GO
Select * from staging.superstore;