/* SQL Server 2017+ on Windows; select a dedicated practice database first.
   Creates only portfolio-owned objects. No database is created, dropped or altered.
   Run files 01 through 05 in order. Rerunning this file retains existing table data. */
SET NOCOUNT ON;
IF DB_NAME() IN ('master','model','msdb','tempdb')
    THROW 50000, 'Select a dedicated user database before running the portfolio.', 1;
GO
IF SCHEMA_ID('retail_stg') IS NULL EXEC('CREATE SCHEMA retail_stg');
IF SCHEMA_ID('retail') IS NULL EXEC('CREATE SCHEMA retail');
IF SCHEMA_ID('retail_audit') IS NULL EXEC('CREATE SCHEMA retail_audit');
GO
-- Every imported field, including the helper's source record number, starts as text.
IF OBJECT_ID('retail_stg.customers','U') IS NULL
CREATE TABLE retail_stg.customers (
 source_row nvarchar(200), customer_id nvarchar(200), customer_name nvarchar(200),
 region nvarchar(200), segment nvarchar(200), email nvarchar(200));
IF OBJECT_ID('retail_stg.products','U') IS NULL
CREATE TABLE retail_stg.products (
 source_row nvarchar(200), product_id nvarchar(200), product_name nvarchar(200),
 category nvarchar(200), list_price nvarchar(200));
IF OBJECT_ID('retail_stg.orders','U') IS NULL
CREATE TABLE retail_stg.orders (
 source_row nvarchar(200), order_id nvarchar(200), customer_id nvarchar(200),
 order_date nvarchar(200), channel nvarchar(200), status nvarchar(200));
IF OBJECT_ID('retail_stg.order_lines','U') IS NULL
CREATE TABLE retail_stg.order_lines (
 source_row nvarchar(200), order_line_id nvarchar(200), order_id nvarchar(200),
 product_id nvarchar(200), quantity nvarchar(200), unit_price nvarchar(200),
 discount_rate nvarchar(200));
IF OBJECT_ID('retail_stg.returns','U') IS NULL
CREATE TABLE retail_stg.returns (
 source_row nvarchar(200), return_id nvarchar(200), order_line_id nvarchar(200),
 return_date nvarchar(200), return_quantity nvarchar(200), reason nvarchar(200));
IF OBJECT_ID('retail_audit.Disposition','U') IS NULL
CREATE TABLE retail_audit.Disposition (
 source_table varchar(20) NOT NULL, source_row int NOT NULL,
 business_key nvarchar(200) NULL, disposition varchar(10) NOT NULL,
 reason nvarchar(300) NULL, retained_source_row int NULL, raw_json nvarchar(max) NOT NULL,
 CONSTRAINT PK_RetailDisposition PRIMARY KEY(source_table,source_row),
 CONSTRAINT CK_RetailDisposition CHECK(disposition IN ('Accepted','Duplicate','Rejected')),
 CONSTRAINT CK_RetailRawJson CHECK(ISJSON(raw_json)=1));
IF OBJECT_ID('retail.Calendar','U') IS NULL
CREATE TABLE retail.Calendar (
 calendar_date date NOT NULL CONSTRAINT PK_RetailCalendar PRIMARY KEY,
 calendar_year smallint NOT NULL, month_number tinyint NOT NULL, month_start date NOT NULL,
 CONSTRAINT CK_RetailCalendar2025 CHECK(calendar_date>='20250101' AND calendar_date<'20260101'));
IF OBJECT_ID('retail.Customer','U') IS NULL
CREATE TABLE retail.Customer (
 customer_id varchar(5) NOT NULL CONSTRAINT PK_RetailCustomer PRIMARY KEY,
 customer_name nvarchar(100) NOT NULL, region varchar(10) NOT NULL,
 segment varchar(10) NOT NULL, email nvarchar(200) NULL,
 CONSTRAINT CK_RetailRegion CHECK(region IN ('North','South','East','West')),
 CONSTRAINT CK_RetailSegment CHECK(segment IN ('Consumer','Business')));
IF OBJECT_ID('retail.Product','U') IS NULL
CREATE TABLE retail.Product (
 product_id varchar(4) NOT NULL CONSTRAINT PK_RetailProduct PRIMARY KEY,
 product_name nvarchar(100) NOT NULL, category varchar(30) NOT NULL,
 list_price decimal(12,2) NOT NULL CONSTRAINT CK_RetailListPrice CHECK(list_price>0));
IF OBJECT_ID('retail.Orders','U') IS NULL
CREATE TABLE retail.Orders (
 order_id varchar(6) NOT NULL CONSTRAINT PK_RetailOrders PRIMARY KEY,
 customer_id varchar(5) NOT NULL REFERENCES retail.Customer(customer_id),
 order_date date NOT NULL REFERENCES retail.Calendar(calendar_date),
 channel varchar(10) NOT NULL, status varchar(10) NOT NULL,
 CONSTRAINT CK_RetailOrderDate CHECK(order_date>='20250101' AND order_date<'20260101'),
 CONSTRAINT CK_RetailChannel CHECK(channel IN ('Online','Store')),
 CONSTRAINT CK_RetailStatus CHECK(status IN ('Completed','Cancelled')));
IF OBJECT_ID('retail.OrderLine','U') IS NULL
CREATE TABLE retail.OrderLine (
 order_line_id varchar(7) NOT NULL CONSTRAINT PK_RetailOrderLine PRIMARY KEY,
 order_id varchar(6) NOT NULL REFERENCES retail.Orders(order_id),
 product_id varchar(4) NOT NULL REFERENCES retail.Product(product_id),
 quantity int NOT NULL CONSTRAINT CK_RetailQuantity CHECK(quantity>0),
 unit_price decimal(12,2) NOT NULL CONSTRAINT CK_RetailUnitPrice CHECK(unit_price>0),
 discount_rate decimal(5,4) NOT NULL CONSTRAINT CK_RetailDiscount CHECK(discount_rate BETWEEN 0 AND 1));
IF OBJECT_ID('retail.ReturnEvent','U') IS NULL
CREATE TABLE retail.ReturnEvent (
 return_id varchar(6) NOT NULL CONSTRAINT PK_RetailReturnEvent PRIMARY KEY,
 order_line_id varchar(7) NOT NULL REFERENCES retail.OrderLine(order_line_id),
 return_date date NOT NULL CONSTRAINT CK_RetailReturnCutoff CHECK(return_date<='20260130'),
 return_quantity int NOT NULL CONSTRAINT CK_RetailReturnQuantity CHECK(return_quantity>0),
 reason nvarchar(100) NOT NULL);
GO
CREATE OR ALTER FUNCTION retail.CleanText(@value nvarchar(4000))
RETURNS nvarchar(4000) AS
BEGIN
 RETURN NULLIF(LTRIM(RTRIM(@value)),N'');
END;
GO
CREATE OR ALTER FUNCTION retail.ExplicitDate(@value nvarchar(200))
RETURNS date AS
BEGIN
 DECLARE @s nvarchar(200)=retail.CleanText(@value);
 RETURN CASE
  WHEN LEN(@s)=10 AND @s LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
   THEN TRY_CONVERT(date,@s,23)
  WHEN LEN(@s)=10 AND @s LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'
   THEN TRY_CONVERT(date,@s,101) END;
END;
GO
-- The locale is explicit; missing/malformed numbers stay NULL, never zero.
CREATE OR ALTER FUNCTION retail.USNumber(@value nvarchar(200))
RETURNS decimal(28,10) AS
BEGIN
 RETURN TRY_PARSE(retail.CleanText(@value) AS decimal(28,10) USING 'en-US');
END;
GO
CREATE OR ALTER VIEW retail.vLineSales AS
WITH Returned AS (
 SELECT order_line_id,SUM(return_quantity) AS returned_units
 FROM retail.ReturnEvent WHERE return_date<='20260130' GROUP BY order_line_id
)
SELECT l.order_line_id,o.order_id,o.customer_id,o.order_date,c.month_start,
 o.channel,l.product_id,p.product_name,p.category,l.quantity AS sold_units,
 COALESCE(r.returned_units,0) AS returned_units,l.unit_price,l.discount_rate,
 CAST(l.quantity*l.unit_price AS decimal(28,6)) AS gross_sales,
 CAST(l.quantity*l.unit_price*l.discount_rate AS decimal(28,6)) AS discounts,
 CAST(l.quantity*l.unit_price*(1-l.discount_rate) AS decimal(28,6)) AS sales_before_returns,
 CAST(COALESCE(r.returned_units,0)*l.unit_price*(1-l.discount_rate) AS decimal(28,6)) AS refunds,
 CAST((l.quantity-COALESCE(r.returned_units,0))*l.unit_price*(1-l.discount_rate) AS decimal(28,6)) AS net_sales
FROM retail.OrderLine l JOIN retail.Orders o ON o.order_id=l.order_id
JOIN retail.Product p ON p.product_id=l.product_id
JOIN retail.Calendar c ON c.calendar_date=o.order_date
LEFT JOIN Returned r ON r.order_line_id=l.order_line_id
WHERE o.status='Completed' AND o.order_date>='20250101' AND o.order_date<'20260101';
GO
-- One row per completed order, including an order with zero retained lines.
CREATE OR ALTER VIEW retail.vOrderSales AS
SELECT o.order_id,o.customer_id,o.order_date,c.month_start,o.channel,
 COALESCE(SUM(s.net_sales),0) AS net_sales,
 COALESCE(SUM(s.sold_units),0) AS sold_units,
 COALESCE(SUM(s.returned_units),0) AS returned_units
FROM retail.Orders o JOIN retail.Calendar c ON c.calendar_date=o.order_date
LEFT JOIN retail.vLineSales s ON s.order_id=o.order_id
WHERE o.status='Completed'
GROUP BY o.order_id,o.customer_id,o.order_date,c.month_start,o.channel;
GO
CREATE OR ALTER VIEW retail_audit.vQualitySummary AS
SELECT source_table,COUNT(*) AS raw_rows,
 SUM(CASE WHEN disposition='Accepted' THEN 1 ELSE 0 END) AS accepted_rows,
 SUM(CASE WHEN disposition='Duplicate' THEN 1 ELSE 0 END) AS duplicate_rows,
 SUM(CASE WHEN disposition='Rejected' THEN 1 ELSE 0 END) AS rejected_rows
FROM retail_audit.Disposition GROUP BY source_table;
GO
