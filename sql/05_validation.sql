/* Run after 03. Each failure raises an error; the last result is emitted only if
   every assertion passes. These are fixed-dataset benchmarks, not claimed runs.
   Run 02,03,05 a second time to verify reload reproducibility on your server. */
SET NOCOUNT ON;
DECLARE @Expected TABLE(source_table varchar(20) PRIMARY KEY,raw_rows int,accepted_rows int,duplicate_rows int,rejected_rows int);
INSERT @Expected VALUES
 ('customers',304,300,4,0),('products',26,24,2,0),('orders',1813,1800,12,1),
 ('order_lines',4476,4446,25,5),('returns',339,335,3,1);
IF EXISTS(SELECT 1 FROM @Expected e FULL JOIN retail_audit.vQualitySummary a ON a.source_table=e.source_table
 WHERE e.source_table IS NULL OR a.source_table IS NULL OR e.raw_rows<>a.raw_rows
 OR e.accepted_rows<>a.accepted_rows OR e.duplicate_rows<>a.duplicate_rows OR e.rejected_rows<>a.rejected_rows)
 THROW 50100, 'Raw/accepted/duplicate/rejected counts differ from benchmarks.', 1;
IF EXISTS(SELECT 1 FROM retail_audit.vQualitySummary WHERE raw_rows<>accepted_rows+duplicate_rows+rejected_rows)
 THROW 50101, 'Raw disposition accounting failed.', 1;
DECLARE @Actual TABLE(source_table varchar(20),raw_rows int,clean_rows int);
INSERT @Actual
SELECT 'customers',(SELECT COUNT(*) FROM retail_stg.customers),(SELECT COUNT(*) FROM retail.Customer)
UNION ALL SELECT 'products',(SELECT COUNT(*) FROM retail_stg.products),(SELECT COUNT(*) FROM retail.Product)
UNION ALL SELECT 'orders',(SELECT COUNT(*) FROM retail_stg.orders),(SELECT COUNT(*) FROM retail.Orders)
UNION ALL SELECT 'order_lines',(SELECT COUNT(*) FROM retail_stg.order_lines),(SELECT COUNT(*) FROM retail.OrderLine)
UNION ALL SELECT 'returns',(SELECT COUNT(*) FROM retail_stg.returns),(SELECT COUNT(*) FROM retail.ReturnEvent);
IF EXISTS(SELECT 1 FROM @Actual a JOIN @Expected e ON a.source_table=e.source_table
 WHERE a.raw_rows<>e.raw_rows OR a.clean_rows<>e.accepted_rows)
 THROW 50102, 'Physical staging/model counts differ from benchmarks.', 1;
IF (SELECT COUNT(*) FROM retail.Calendar)<>365
 OR (SELECT MIN(calendar_date) FROM retail.Calendar)<>'20250101'
 OR (SELECT MAX(calendar_date) FROM retail.Calendar)<>'20251231'
 OR (SELECT COUNT(DISTINCT month_start) FROM retail.Calendar)<>12
 THROW 50103, 'Calendar must contain all 365 days and 12 months of 2025.', 1;
IF EXISTS(SELECT 1 FROM retail.Calendar WHERE calendar_year<>YEAR(calendar_date)
 OR month_number<>MONTH(calendar_date) OR month_start<>DATEFROMPARTS(YEAR(calendar_date),MONTH(calendar_date),1))
 THROW 50104, 'Calendar attributes do not match their dates.', 1;
IF (SELECT COUNT(*) FROM retail.Orders WHERE status='Completed')<>1661
 OR (SELECT COUNT(*) FROM retail.Orders WHERE status='Cancelled')<>139
 THROW 50105, 'Completed/cancelled order counts differ from benchmarks.', 1;
IF EXISTS(SELECT 1 FROM retail.OrderLine l LEFT JOIN retail.Orders o ON o.order_id=l.order_id
 LEFT JOIN retail.Product p ON p.product_id=l.product_id WHERE o.order_id IS NULL OR p.product_id IS NULL)
 OR EXISTS(SELECT 1 FROM retail.Orders o LEFT JOIN retail.Customer c ON c.customer_id=o.customer_id WHERE c.customer_id IS NULL)
 THROW 50106, 'Model contains an orphan order or line.', 1;
IF EXISTS(SELECT 1 FROM retail.ReturnEvent r LEFT JOIN retail.OrderLine l ON l.order_line_id=r.order_line_id
 LEFT JOIN retail.Orders o ON o.order_id=l.order_id
 WHERE l.order_line_id IS NULL OR o.status<>'Completed' OR r.return_date<o.order_date OR r.return_date>'20260130')
 OR EXISTS(SELECT 1 FROM retail.ReturnEvent r JOIN retail.OrderLine l ON l.order_line_id=r.order_line_id
 GROUP BY r.order_line_id,l.quantity HAVING SUM(CONVERT(bigint,r.return_quantity))>l.quantity)
 THROW 50107, 'Invalid return parent, status, date, or cumulative quantity.', 1;
IF EXISTS(SELECT 1 FROM retail.ReturnEvent WHERE return_id='RX001')
 OR NOT EXISTS(SELECT 1 FROM retail.ReturnEvent WHERE return_id='R00001')
 THROW 50108, 'The bad return must be removed while the legitimate shared-line return survives.', 1;
IF (SELECT COUNT(*) FROM retail_audit.Disposition WHERE disposition='Rejected'
 AND business_key IN ('OX0001','X000001','X000002','X000003','X000004','X000005','RX001'))<>7
 THROW 50109, 'Expected invalid record IDs were not all quarantined.', 1;
IF (SELECT COUNT(*) FROM retail.vLineSales)<>(SELECT COUNT(*) FROM retail.OrderLine l JOIN retail.Orders o ON o.order_id=l.order_id WHERE o.status='Completed')
 OR EXISTS(SELECT order_line_id FROM retail.vLineSales GROUP BY order_line_id HAVING COUNT(*)<>1)
 THROW 50110, 'Analytical joins changed completed-line grain.', 1;
IF (SELECT COUNT(*) FROM retail.vOrderSales)<>1661
 OR EXISTS(SELECT order_id FROM retail.vOrderSales GROUP BY order_id HAVING COUNT(*)<>1)
 THROW 50111, 'Order sales does not have one row per completed order.', 1;

DECLARE @gross decimal(28,6),@discounts decimal(28,6),@refunds decimal(28,6),@net decimal(28,6),
 @sold bigint,@returned bigint,@monthly_net decimal(28,6),@order_net decimal(28,6);
SELECT @gross=SUM(gross_sales),@discounts=SUM(discounts),@refunds=SUM(refunds),@net=SUM(net_sales),
 @sold=SUM(CONVERT(bigint,sold_units)),@returned=SUM(CONVERT(bigint,returned_units)) FROM retail.vLineSales;
IF @gross IS NULL OR ABS(@gross-2170836.000000)>0.000001
 OR ABS(@discounts-194394.300000)>0.000001 OR ABS(@refunds-100947.100000)>0.000001
 OR ABS(@net-1875494.600000)>0.000001 OR @sold<>12354 OR @returned<>648
 THROW 50112, 'Annual monetary or unit benchmarks do not reconcile.', 1;
IF ABS(@net-(@gross-@discounts-@refunds))>0.000001
 THROW 50113, 'Gross less discounts less refunds does not equal net sales.', 1;
WITH Months AS (SELECT DISTINCT month_start FROM retail.Calendar),
 Monthly AS (SELECT month_start,SUM(net_sales) AS net_sales FROM retail.vOrderSales GROUP BY month_start)
SELECT @monthly_net=SUM(COALESCE(m.net_sales,0)) FROM Months d LEFT JOIN Monthly m ON m.month_start=d.month_start;
SELECT @order_net=SUM(net_sales) FROM retail.vOrderSales;
IF @monthly_net IS NULL OR @order_net IS NULL OR ABS(@monthly_net-@net)>0.000001 OR ABS(@order_net-@net)>0.000001
 THROW 50114, 'Monthly, order, and line totals do not reconcile.', 1;

SELECT 'PASS: all fixed-dataset SQL assertions passed on this server' AS validation_status,
 CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS sql_server_version,DB_NAME() AS database_name,
 SYSDATETIMEOFFSET() AS verified_at,@gross AS gross_sales,@discounts AS discounts,@refunds AS refunds,
 @net AS net_sales,@sold AS sold_units,@returned AS returned_units;
SELECT * FROM retail_audit.vQualitySummary ORDER BY source_table;
