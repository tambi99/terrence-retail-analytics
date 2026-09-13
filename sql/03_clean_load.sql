/* Atomic, repeatable cleaning of the current five staging tables.
   Raw staging is preserved. Original values and one disposition per source record
   are persisted in retail_audit.Disposition. This replaces only portfolio output.
   Run after 01_schema.sql and 02_import.sql. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() IN ('master','model','msdb','tempdb')
 THROW 50000, 'Select the dedicated portfolio database.', 1;
DROP TABLE IF EXISTS #Source,#Ranked,#Unique,#Conflicts,#Work,#Customer,#Product,#Orders,#Line,#Return,#Cumulative;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @lock_result int;
 EXEC @lock_result=sys.sp_getapplock @Resource=N'RetailPortfolioReload',
  @LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000;
 IF @lock_result<0 THROW 50001, 'Another portfolio load is running; retry later.', 1;
 CREATE TABLE #Source(source_table varchar(20),source_row int,business_key nvarchar(200),raw_json nvarchar(max));
 INSERT #Source
 SELECT 'customers',CONVERT(int,s.source_row),UPPER(retail.CleanText(s.customer_id)),
  (SELECT s.customer_id,s.customer_name,s.region,s.segment,s.email FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER)
 FROM retail_stg.customers s
 UNION ALL
 SELECT 'products',CONVERT(int,s.source_row),UPPER(retail.CleanText(s.product_id)),
  (SELECT s.product_id,s.product_name,s.category,s.list_price FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER)
 FROM retail_stg.products s
 UNION ALL
 SELECT 'orders',CONVERT(int,s.source_row),UPPER(retail.CleanText(s.order_id)),
  (SELECT s.order_id,s.customer_id,s.order_date,s.channel,s.status FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER)
 FROM retail_stg.orders s
 UNION ALL
 SELECT 'order_lines',CONVERT(int,s.source_row),UPPER(retail.CleanText(s.order_line_id)),
  (SELECT s.order_line_id,s.order_id,s.product_id,s.quantity,s.unit_price,s.discount_rate FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER)
 FROM retail_stg.order_lines s
 UNION ALL
 SELECT 'returns',CONVERT(int,s.source_row),UPPER(retail.CleanText(s.return_id)),
  (SELECT s.return_id,s.order_line_id,s.return_date,s.return_quantity,s.reason FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER)
 FROM retail_stg.returns s;
 IF (SELECT COUNT(DISTINCT source_table) FROM #Source)<>5
  THROW 50010, 'All five nonempty staging tables are required.', 1;
 IF EXISTS(SELECT 1 FROM #Source WHERE source_row IS NULL OR source_row<1)
  THROW 50011, 'Invalid source record number.', 1;
 IF EXISTS(SELECT source_table,source_row FROM #Source GROUP BY source_table,source_row HAVING COUNT(*)>1)
  THROW 50012, 'Source record numbers must be unique within each file.', 1;

 -- JSON uses every original business field in a fixed order. Binary collation
 -- keeps text case-sensitive; spaces inside JSON string values remain significant.
 -- The source record number is deliberately absent from the duplicate comparison.
 SELECT *,ROW_NUMBER() OVER(PARTITION BY source_table,raw_json COLLATE Latin1_General_100_BIN2
   ORDER BY source_row) AS duplicate_rank,
  MIN(source_row) OVER(PARTITION BY source_table,raw_json COLLATE Latin1_General_100_BIN2) AS retained_source_row
 INTO #Ranked FROM #Source;
 SELECT * INTO #Unique FROM #Ranked WHERE duplicate_rank=1;
 SELECT source_table,business_key INTO #Conflicts FROM #Unique
 GROUP BY source_table,business_key HAVING COUNT(*)>1;
 SELECT u.* INTO #Work FROM #Unique u
 WHERE NOT EXISTS(SELECT 1 FROM #Conflicts c WHERE c.source_table=u.source_table
  AND (c.business_key=u.business_key OR (c.business_key IS NULL AND u.business_key IS NULL)));

 -- Child-to-parent replacement is safe on rerun; all changes roll back together.
 DELETE FROM retail.ReturnEvent;
 DELETE FROM retail.OrderLine;
 DELETE FROM retail.Orders;
 DELETE FROM retail.Product;
 DELETE FROM retail.Customer;
 DELETE FROM retail.Calendar;
 DELETE FROM retail_audit.Disposition;
 INSERT retail_audit.Disposition
 SELECT source_table,source_row,business_key,'Duplicate','Exact duplicate of original business fields',retained_source_row,raw_json
 FROM #Ranked WHERE duplicate_rank>1;
 INSERT retail_audit.Disposition
 SELECT u.source_table,u.source_row,u.business_key,'Rejected','Conflicting records share a normalized business key',NULL,u.raw_json
 FROM #Unique u WHERE EXISTS(SELECT 1 FROM #Conflicts c WHERE c.source_table=u.source_table
  AND (c.business_key=u.business_key OR (c.business_key IS NULL AND u.business_key IS NULL)));

 ;WITH Days AS (
  SELECT CONVERT(date,'20250101',112) AS d
  UNION ALL SELECT DATEADD(day,1,d) FROM Days WHERE d<CONVERT(date,'20251231',112)
 )
 INSERT retail.Calendar(calendar_date,calendar_year,month_number,month_start)
 SELECT d,YEAR(d),MONTH(d),DATEFROMPARTS(YEAR(d),MONTH(d),1) FROM Days OPTION(MAXRECURSION 365);

 -- 1. Customers: missing email is allowed.
 SELECT w.*,t.customer_name,t.region,t.segment,t.email,
  CAST(CASE
   WHEN w.business_key IS NULL OR LEN(w.business_key)>5 THEN 'Invalid customer ID'
   WHEN t.customer_name IS NULL OR LEN(t.customer_name)>100 THEN 'Missing or overlength customer name'
   WHEN t.region IS NULL THEN 'Unrecognized region'
   WHEN t.segment IS NULL THEN 'Unrecognized segment'
   END AS nvarchar(300)) AS rejection_reason
 INTO #Customer FROM #Work w CROSS APPLY(SELECT
  retail.CleanText(JSON_VALUE(w.raw_json,'$.customer_name')) AS customer_name,
  CASE UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.region')))
   WHEN 'NORTH' THEN 'North' WHEN 'SOUTH' THEN 'South' WHEN 'EAST' THEN 'East' WHEN 'WEST' THEN 'West' END AS region,
  CASE UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.segment')))
   WHEN 'CONSUMER' THEN 'Consumer' WHEN 'BUSINESS' THEN 'Business' END AS segment,
  retail.CleanText(JSON_VALUE(w.raw_json,'$.email')) AS email
 ) t WHERE w.source_table='customers';
 INSERT retail.Customer(customer_id,customer_name,region,segment,email)
 SELECT business_key,customer_name,region,segment,email FROM #Customer WHERE rejection_reason IS NULL;
 INSERT retail_audit.Disposition
 SELECT source_table,source_row,business_key,CASE WHEN rejection_reason IS NULL THEN 'Accepted' ELSE 'Rejected' END,
  rejection_reason,NULL,raw_json FROM #Customer;

 -- 2. Products: descriptive list price, never substituted for a transaction price.
 SELECT w.*,t.product_name,t.category,t.list_price,
  CAST(CASE
   WHEN w.business_key IS NULL OR LEN(w.business_key)>4 THEN 'Invalid product ID'
   WHEN t.product_name IS NULL OR LEN(t.product_name)>100 THEN 'Missing or overlength product name'
   WHEN t.category IS NULL OR LEN(t.category)>30 THEN 'Missing or overlength category'
   WHEN t.list_price IS NULL OR t.list_price<=0 THEN 'List price must be a positive number'
   WHEN TRY_CONVERT(decimal(12,2),t.list_price) IS NULL OR t.list_price<>TRY_CONVERT(decimal(12,2),t.list_price)
    THEN 'List price is outside the model precision'
   END AS nvarchar(300)) AS rejection_reason
 INTO #Product FROM #Work w CROSS APPLY(SELECT
  retail.CleanText(JSON_VALUE(w.raw_json,'$.product_name')) AS product_name,
  UPPER(LEFT(retail.CleanText(JSON_VALUE(w.raw_json,'$.category')),1))+
   LOWER(SUBSTRING(retail.CleanText(JSON_VALUE(w.raw_json,'$.category')),2,200)) AS category,
  retail.USNumber(REPLACE(JSON_VALUE(w.raw_json,'$.list_price'),'$','')) AS list_price
 ) t WHERE w.source_table='products';
 INSERT retail.Product(product_id,product_name,category,list_price)
 SELECT business_key,product_name,category,TRY_CONVERT(decimal(12,2),list_price) FROM #Product WHERE rejection_reason IS NULL;
 INSERT retail_audit.Disposition
 SELECT source_table,source_row,business_key,CASE WHEN rejection_reason IS NULL THEN 'Accepted' ELSE 'Rejected' END,
  rejection_reason,NULL,raw_json FROM #Product;

 -- 3. Orders: explicit ISO/US dates; valid cancelled orders stay in the model.
 SELECT w.*,t.customer_id,t.order_date,t.channel,t.status,
  CAST(CASE
   WHEN w.business_key IS NULL OR LEN(w.business_key)>6 THEN 'Invalid order ID'
   WHEN t.order_date IS NULL THEN 'Invalid order date: require ISO yyyy-MM-dd or US MM/dd/yyyy'
   WHEN t.order_date<'20250101' OR t.order_date>='20260101' THEN 'Order date is outside 2025'
   WHEN c.customer_id IS NULL THEN 'Unknown or rejected customer'
   WHEN t.channel IS NULL THEN 'Unrecognized channel'
   WHEN t.status IS NULL THEN 'Unrecognized order status'
   END AS nvarchar(300)) AS rejection_reason
 INTO #Orders FROM #Work w CROSS APPLY(SELECT
  UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.customer_id'))) AS customer_id,
  retail.ExplicitDate(JSON_VALUE(w.raw_json,'$.order_date')) AS order_date,
  CASE UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.channel')))
   WHEN 'WEB' THEN 'Online' WHEN 'ONLINE' THEN 'Online' WHEN 'RETAIL' THEN 'Store' WHEN 'STORE' THEN 'Store' END AS channel,
  CASE UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.status')))
   WHEN 'COMPLETED' THEN 'Completed' WHEN 'CANCELLED' THEN 'Cancelled' END AS status
 ) t LEFT JOIN retail.Customer c ON c.customer_id=t.customer_id WHERE w.source_table='orders';
 INSERT retail.Orders(order_id,customer_id,order_date,channel,status)
 SELECT business_key,customer_id,order_date,channel,status FROM #Orders WHERE rejection_reason IS NULL;
 INSERT retail_audit.Disposition
 SELECT source_table,source_row,business_key,CASE WHEN rejection_reason IS NULL THEN 'Accepted' ELSE 'Rejected' END,
  rejection_reason,NULL,raw_json FROM #Orders;

 -- 4. Lines: a repeated order/product pair can be a legitimate different line.
 SELECT w.*,t.order_id,t.product_id,t.quantity,t.unit_price,t.discount_rate,
  CAST(CASE
   WHEN w.business_key IS NULL OR LEN(w.business_key)>7 THEN 'Invalid order-line ID'
   WHEN o.order_id IS NULL THEN 'Unknown or rejected order'
   WHEN p.product_id IS NULL THEN 'Unknown or rejected product'
   WHEN t.quantity IS NULL OR t.quantity<=0 OR TRY_CONVERT(int,t.quantity) IS NULL
    OR t.quantity<>TRY_CONVERT(int,t.quantity) THEN 'Quantity must be a positive integer'
   WHEN t.unit_price IS NULL OR t.unit_price<=0 THEN 'Unit price must be a positive number'
   WHEN TRY_CONVERT(decimal(12,2),t.unit_price) IS NULL OR t.unit_price<>TRY_CONVERT(decimal(12,2),t.unit_price)
    THEN 'Unit price is outside the model precision'
   WHEN t.discount_rate IS NULL OR t.discount_rate<0 OR t.discount_rate>1 THEN 'Discount must be between zero and one'
   WHEN t.discount_rate<>TRY_CONVERT(decimal(5,4),t.discount_rate) THEN 'Discount is outside the model precision'
   END AS nvarchar(300)) AS rejection_reason
 INTO #Line FROM #Work w CROSS APPLY(SELECT
  UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.order_id'))) AS order_id,
  UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.product_id'))) AS product_id,
  retail.USNumber(JSON_VALUE(w.raw_json,'$.quantity')) AS quantity,
  retail.USNumber(REPLACE(JSON_VALUE(w.raw_json,'$.unit_price'),'$','')) AS unit_price,
  CASE WHEN RIGHT(retail.CleanText(JSON_VALUE(w.raw_json,'$.discount_rate')),1)='%'
   THEN retail.USNumber(LEFT(retail.CleanText(JSON_VALUE(w.raw_json,'$.discount_rate')),
    LEN(retail.CleanText(JSON_VALUE(w.raw_json,'$.discount_rate')))-1))/100
   ELSE retail.USNumber(JSON_VALUE(w.raw_json,'$.discount_rate')) END AS discount_rate
 ) t LEFT JOIN retail.Orders o ON o.order_id=t.order_id
 LEFT JOIN retail.Product p ON p.product_id=t.product_id WHERE w.source_table='order_lines';
 INSERT retail.OrderLine(order_line_id,order_id,product_id,quantity,unit_price,discount_rate)
 SELECT business_key,order_id,product_id,TRY_CONVERT(int,quantity),TRY_CONVERT(decimal(12,2),unit_price),
  TRY_CONVERT(decimal(5,4),discount_rate) FROM #Line WHERE rejection_reason IS NULL;
 INSERT retail_audit.Disposition
 SELECT source_table,source_row,business_key,CASE WHEN rejection_reason IS NULL THEN 'Accepted' ELSE 'Rejected' END,
  rejection_reason,NULL,raw_json FROM #Line;

 -- 5. Returns: FIRST remove individually invalid events (including quantity>sold).
 -- RX001 shares a line with a legitimate event. Its quantity 999 must not cause
 -- the legitimate event to be rejected during the later cumulative check.
 SELECT w.*,t.order_line_id,t.return_date,t.return_quantity,t.reason,l.quantity AS purchased_units,
  CAST(CASE
   WHEN w.business_key IS NULL OR LEN(w.business_key)>6 THEN 'Invalid return ID'
   WHEN l.order_line_id IS NULL THEN 'Unknown or rejected order line'
   WHEN o.status<>'Completed' THEN 'Returns require a completed order'
   WHEN t.return_date IS NULL THEN 'Invalid return date: require ISO yyyy-MM-dd or US MM/dd/yyyy'
   WHEN t.return_date<o.order_date THEN 'Return date precedes order date'
   WHEN t.return_date>'20260130' THEN 'Return date is after the 2026-01-30 cutoff'
   WHEN t.return_quantity IS NULL OR t.return_quantity<=0 OR TRY_CONVERT(int,t.return_quantity) IS NULL
    OR t.return_quantity<>TRY_CONVERT(int,t.return_quantity) THEN 'Return quantity must be a positive integer'
   WHEN t.return_quantity>l.quantity THEN 'Individual return quantity exceeds purchased units'
   WHEN t.reason IS NULL OR LEN(t.reason)>100 THEN 'Missing or overlength return reason'
   END AS nvarchar(300)) AS rejection_reason
 INTO #Return FROM #Work w CROSS APPLY(SELECT
  UPPER(retail.CleanText(JSON_VALUE(w.raw_json,'$.order_line_id'))) AS order_line_id,
  retail.ExplicitDate(JSON_VALUE(w.raw_json,'$.return_date')) AS return_date,
  retail.USNumber(JSON_VALUE(w.raw_json,'$.return_quantity')) AS return_quantity,
  retail.CleanText(JSON_VALUE(w.raw_json,'$.reason')) AS reason
 ) t LEFT JOIN retail.OrderLine l ON l.order_line_id=t.order_line_id
 LEFT JOIN retail.Orders o ON o.order_id=l.order_id WHERE w.source_table='returns';
 -- If otherwise valid events collectively exceed sold units, quarantine ALL
 -- remaining events on that line for review; do not choose a survivor arbitrarily.
 SELECT order_line_id,SUM(return_quantity) AS returned_units INTO #Cumulative
 FROM #Return WHERE rejection_reason IS NULL GROUP BY order_line_id;
 UPDATE r SET rejection_reason='Cumulative otherwise-valid returns exceed purchased units; review all events on line'
 FROM #Return r JOIN #Cumulative c ON c.order_line_id=r.order_line_id
 WHERE r.rejection_reason IS NULL AND c.returned_units>r.purchased_units;
 INSERT retail.ReturnEvent(return_id,order_line_id,return_date,return_quantity,reason)
 SELECT business_key,order_line_id,return_date,TRY_CONVERT(int,return_quantity),reason
 FROM #Return WHERE rejection_reason IS NULL;
 INSERT retail_audit.Disposition
 SELECT source_table,source_row,business_key,CASE WHEN rejection_reason IS NULL THEN 'Accepted' ELSE 'Rejected' END,
  rejection_reason,NULL,raw_json FROM #Return;

 IF (SELECT COUNT(*) FROM #Source)<>(SELECT COUNT(*) FROM retail_audit.Disposition)
  THROW 50013, 'Not every source record received exactly one disposition.', 1;
 IF EXISTS(SELECT 1 FROM retail.ReturnEvent r JOIN retail.OrderLine l ON l.order_line_id=r.order_line_id
  GROUP BY r.order_line_id,l.quantity HAVING SUM(CONVERT(bigint,r.return_quantity))>l.quantity)
  THROW 50014, 'Cumulative return validation failed.', 1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
SELECT * FROM retail_audit.vQualitySummary ORDER BY source_table;
SELECT source_table,source_row,business_key,reason,raw_json
FROM retail_audit.Disposition WHERE disposition='Rejected' ORDER BY source_table,source_row;
