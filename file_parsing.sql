BULK INSERT staging.customers_raw
FROM 'D:\imports\customers_2024.csv'
WITH (
    FIRSTROW = 2,              -- skip the header row
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',        -- UTF-8
    MAXERRORS = 0,
    ERRORFILE = 'D:\imports\errors\customers_2024_err.log'
);