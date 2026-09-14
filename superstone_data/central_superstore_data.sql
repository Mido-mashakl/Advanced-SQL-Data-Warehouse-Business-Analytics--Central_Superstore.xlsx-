IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'superstone_dw')
    CREATE DATABASE superstone_dw;
GO

USE superstone_dw;
GO

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
-- STAGING LAYER
-- ============================================================
-- 1:1 raw mirror of each source file. NVARCHAR(255), no constraints,
-- no cleaning. TRUNCATE + full reload every run (staging holds only
-- the current batch, never history).

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'customers')
BEGIN
    CREATE TABLE staging.customers (
        customer_id NVARCHAR(255),
        first_name NVARCHAR(255),
        last_name NVARCHAR(255),
        email NVARCHAR(255),
        phone NVARCHAR(255),
        signup_date NVARCHAR(255),
        city NVARCHAR(255),
        state NVARCHAR(255),
        country NVARCHAR(255)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'customer_profiles')
BEGIN
    CREATE TABLE staging.customer_profiles (
        profile_id NVARCHAR(255),
        customer_id NVARCHAR(255),
        email NVARCHAR(255),
        loyalty_tier NVARCHAR(255),
        marketing_opt_in NVARCHAR(255),
        preferred_channel NVARCHAR(255),
        birth_date NVARCHAR(255),
        gender NVARCHAR(255)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'products')
BEGIN
    CREATE TABLE staging.products (
        product_id NVARCHAR(255),
        product_name NVARCHAR(255),
        category NVARCHAR(255),
        sub_category NVARCHAR(255),
        brand NVARCHAR(255),
        unit_price NVARCHAR(255),
        cost_price NVARCHAR(255)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'product_inventory')
BEGIN
    CREATE TABLE staging.product_inventory (
        inventory_id NVARCHAR(255),
        product_id NVARCHAR(255),
        warehouse_location NVARCHAR(255),
        stock_quantity NVARCHAR(255),
        reorder_level NVARCHAR(255),
        supplier_name NVARCHAR(255),
        last_restock_date NVARCHAR(255)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'orders')
BEGIN
    CREATE TABLE staging.orders (
        order_id NVARCHAR(255),
        customer_id NVARCHAR(255),
        order_date NVARCHAR(255),
        order_status NVARCHAR(255),
        channel NVARCHAR(255),
        shipping_city NVARCHAR(255),
        shipping_state NVARCHAR(255)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'order_items')
BEGIN
    CREATE TABLE staging.order_items (
        order_item_id NVARCHAR(255),
        order_id NVARCHAR(255),
        product_id NVARCHAR(255),
        quantity NVARCHAR(255),
        unit_price NVARCHAR(255),
        discount_pct NVARCHAR(255)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'staging' AND t.name = 'payments')
BEGIN
    CREATE TABLE staging.payments (
        payment_id NVARCHAR(255),
        order_id NVARCHAR(255),
        payment_method NVARCHAR(255),
        amount NVARCHAR(255),
        payment_date NVARCHAR(255),
        payment_status NVARCHAR(255)
    );
END;
GO
select * from information_schema.tables;

-- Truncate + reload every staging table from its current batch file.

TRUNCATE TABLE staging.customers;

BULK INSERT staging.customers
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\customers_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\customers_err.log'
);
GO
Select * from staging.customers;
TRUNCATE TABLE staging.customer_profiles;

BULK INSERT staging.customer_profiles
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\customer_profiles_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\customer_profiles_err.log'
);
GO
Select * from staging.customer_profiles;
TRUNCATE TABLE staging.products;

BULK INSERT staging.products
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\products_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\products_err.log'
);
GO
Select * from staging.products;
TRUNCATE TABLE staging.product_inventory;

BULK INSERT staging.product_inventory
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\product_inventory_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\product_inventory_err.log'
);
GO
Select * from staging.product_inventory;
TRUNCATE TABLE staging.orders;

BULK INSERT staging.orders
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\orders_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\orders_err.log'
);
GO
Select * from staging.orders;
TRUNCATE TABLE staging.order_items;

BULK INSERT staging.order_items
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\order_items_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\order_items_err.log'
);
GO
Select * from staging.order_items;
TRUNCATE TABLE staging.payments;

BULK INSERT staging.payments
FROM 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\payments_batch1.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',
    MAXERRORS = 0,
    ERRORFILE = 'C:\Users\MZ\Desktop\mido\depi\MSSQL16.SQLEXPRESS\SQL-task-5\data-warehouse\ecommerce_data\batches\payments_err.log'
);
GO
Select * from staging.payments;