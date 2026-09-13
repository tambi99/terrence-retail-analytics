/* Completed solutions: USD; completed 2025 orders; returns through 2026-01-30
   attributed to the original order date. vLineSales aggregates returns BEFORE
   joining lines. Amounts retain precision; round only report presentation. */
SET NOCOUNT ON;

-- 1. Annual KPIs. Order denominator is an order-grain view, never a line count.
WITH Sales AS (
 SELECT SUM(gross_sales) AS gross_sales,SUM(discounts) AS discounts,
  SUM(sales_before_returns) AS sales_before_returns,SUM(refunds) AS refunds,
  SUM(net_sales) AS net_sales,SUM(sold_units) AS sold_units,SUM(returned_units) AS returned_units
 FROM retail.vLineSales
), OrderCount AS (SELECT COUNT(*) AS completed_orders FROM retail.vOrderSales)
SELECT 'USD' AS currency,'2025-01-01 through 2025-12-31' AS order_period,
 CONVERT(date,'20260130',112) AS return_cutoff,s.*,o.completed_orders,
 CAST(s.net_sales AS decimal(28,6))/NULLIF(o.completed_orders,0) AS net_aov,
 CAST(s.returned_units AS decimal(18,6))/NULLIF(s.sold_units,0) AS unit_return_rate
FROM Sales s CROSS JOIN OrderCount o;

-- 2. Chained CTEs, full calendar, LAG, running total and three-month mean.
-- Calendar filling makes a three-row window mean three consecutive months.
WITH Months AS (
 SELECT DISTINCT month_start FROM retail.Calendar
), Monthly AS (
 SELECT month_start,COUNT(*) AS completed_orders,SUM(net_sales) AS net_sales
 FROM retail.vOrderSales GROUP BY month_start
), Filled AS (
 SELECT d.month_start,COALESCE(m.completed_orders,0) AS completed_orders,
  COALESCE(m.net_sales,0) AS net_sales
 FROM Months d LEFT JOIN Monthly m ON m.month_start=d.month_start
), WithPrior AS (
 SELECT *,LAG(net_sales) OVER(ORDER BY month_start) AS prior_net_sales,
  LAG(completed_orders) OVER(ORDER BY month_start) AS prior_orders
 FROM Filled
)
SELECT month_start,completed_orders,net_sales,
 CAST(net_sales AS decimal(28,6))/NULLIF(completed_orders,0) AS net_aov,
 (CAST(net_sales AS decimal(28,6))-CAST(prior_net_sales AS decimal(28,6))) /
  NULLIF(CAST(prior_net_sales AS decimal(28,6)),0) AS mom_net_sales_growth,
 CAST(completed_orders-prior_orders AS decimal(18,6))/NULLIF(prior_orders,0) AS mom_order_growth,
 SUM(net_sales) OVER(ORDER BY month_start ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_net_sales,
 CASE WHEN COUNT(*) OVER(ORDER BY month_start ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)=3
  THEN AVG(net_sales) OVER(ORDER BY month_start ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
 END AS moving_average_3_months
FROM WithPrior ORDER BY month_start;

-- 3. Category contribution. Distinct order counts overlap across categories.
WITH CategorySales AS (
 SELECT category,SUM(net_sales) AS net_sales,SUM(sold_units) AS sold_units,
  SUM(returned_units) AS returned_units,COUNT(DISTINCT order_id) AS completed_orders_with_category
 FROM retail.vLineSales GROUP BY category
)
SELECT *,CAST(net_sales AS decimal(28,6))/NULLIF(CAST(SUM(net_sales) OVER() AS decimal(28,6)),0) AS net_sales_share,
 CAST(returned_units AS decimal(18,6))/NULLIF(sold_units,0) AS unit_return_rate
FROM CategorySales ORDER BY net_sales DESC,category;

-- 4. DENSE_RANK retains ties; a category can return more than three products.
WITH ProductSales AS (
 SELECT category,product_id,product_name,SUM(net_sales) AS net_sales,
  SUM(sold_units) AS sold_units,SUM(returned_units) AS returned_units
 FROM retail.vLineSales GROUP BY category,product_id,product_name
), Ranked AS (
 SELECT *,DENSE_RANK() OVER(PARTITION BY category ORDER BY net_sales DESC) AS category_rank
 FROM ProductSales
)
SELECT * FROM Ranked WHERE category_rank<=3 ORDER BY category,category_rank,product_id;

-- 5. Channel rates use channel-level numerators and denominators.
WITH ChannelSales AS (
 SELECT channel,COUNT(*) AS completed_orders,SUM(net_sales) AS net_sales,
  SUM(sold_units) AS sold_units,SUM(returned_units) AS returned_units
 FROM retail.vOrderSales GROUP BY channel
)
SELECT *,CAST(net_sales AS decimal(28,6))/NULLIF(completed_orders,0) AS net_aov,
 CAST(returned_units AS decimal(18,6))/NULLIF(sold_units,0) AS unit_return_rate
FROM ChannelSales ORDER BY channel;

-- 6. Full-year repeat customers: at least two distinct completed orders in 2025.
-- Their first order is included in their full-year sales share. This is not retention.
WITH CustomerSales AS (
 SELECT customer_id,COUNT(*) AS completed_orders,SUM(net_sales) AS net_sales
 FROM retail.vOrderSales GROUP BY customer_id
)
SELECT COUNT(*) AS purchasing_customers,
 SUM(CASE WHEN completed_orders>=2 THEN 1 ELSE 0 END) AS repeat_customers,
 SUM(CASE WHEN completed_orders>=2 THEN net_sales ELSE 0 END) AS repeat_customer_net_sales,
 CAST(SUM(CASE WHEN completed_orders>=2 THEN net_sales ELSE 0 END) AS decimal(28,6)) /
  NULLIF(CAST(SUM(net_sales) AS decimal(28,6)),0) AS repeat_customer_sales_share
FROM CustomerSales;

-- 7. ROW_NUMBER produces a deterministic observed order sequence for each customer.
SELECT customer_id,order_id,order_date,net_sales,
 ROW_NUMBER() OVER(PARTITION BY customer_id ORDER BY order_date,order_id) AS observed_order_sequence
FROM retail.vOrderSales ORDER BY customer_id,order_date,order_id;

-- 8. Returning-at-purchase sales require an earlier observed ORDER DATE.
-- Same-day orders do not establish an earlier date. History before 2025 is unknown.
WITH FirstObserved AS (
 SELECT customer_id,MIN(order_date) AS first_order_date FROM retail.vOrderSales GROUP BY customer_id
), Monthly AS (
 SELECT o.month_start,SUM(o.net_sales) AS net_sales,
  SUM(CASE WHEN o.order_date>f.first_order_date THEN o.net_sales ELSE 0 END) AS returning_at_purchase_net_sales
 FROM retail.vOrderSales o JOIN FirstObserved f ON f.customer_id=o.customer_id GROUP BY o.month_start
), Months AS (SELECT DISTINCT month_start FROM retail.Calendar)
SELECT d.month_start,COALESCE(m.net_sales,0) AS net_sales,
 COALESCE(m.returning_at_purchase_net_sales,0) AS returning_at_purchase_net_sales,
 CAST(m.returning_at_purchase_net_sales AS decimal(28,6))/NULLIF(CAST(m.net_sales AS decimal(28,6)),0) AS returning_at_purchase_share
FROM Months d LEFT JOIN Monthly m ON m.month_start=d.month_start ORDER BY d.month_start;

-- 9. ROW_NUMBER duplicate evidence: 03 used every original business field,
-- not only the key and never the (order_id,product_id) pair.
SELECT source_table,business_key,source_row,retained_source_row,raw_json
FROM retail_audit.Disposition WHERE disposition='Duplicate' ORDER BY source_table,source_row;
