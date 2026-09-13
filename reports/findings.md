# Retail sales findings

The synthetic retailer recorded **$1,875,494.60 net sales from 1,661 completed orders** in 2025. Net AOV was **$1,129.14** and **648 of 12,354 sold units** were returned, a **5.25% unit return rate**. Returns observed through January 30, 2026 are attributed to their original 2025 order month.

## Where sales came from

West led order volume with **484 orders** and net sales with **$526,887.65**, or **28.1%** of the annual total. Its net AOV, **$1,088.61**, was below the company average. Higher volume therefore did not imply a larger average basket. [Regional results](../analysis/region_summary.csv).

Furniture contributed **$1,051,563.60**, or **56.1%** of net sales; Lighting contributed **$516,029.65** and Storage **$307,901.35**. Storage had the highest category unit return rate, **5.78%**, compared with Furniture's **4.88%**. Before proposing inventory changes, compare product mix, unit demand and return reasons. Product costs and inventory availability are not supplied. [Category results](../analysis/category_summary.csv).

## When sales changed

November had the highest net sales, **$179,274.95**. May had the lowest, **$122,212.30**, down **23.9%** from April. In that April-to-May comparison, completed orders fell from **130 to 125** and net AOV fell from **$1,235.60 to $977.70**. Both contributed to the sales decline; the larger proportional change was in AOV. This supports examining the basket and product mix, but does not identify a causal event. [Monthly results](../analysis/monthly_summary.csv).

## Returns and channel comparison

Online and Store contributed similar net sales: **$942,564.15** and **$932,930.45**. Store had a higher unit return rate: **359 / 6,147 = 5.84%**, compared with Online's **289 / 6,207 = 4.66%**, a **1.18 percentage-point** difference. Compare category and product mix within channels before attributing this to service or fulfillment quality. [Channel results](../analysis/channel_summary.csv).

## Interpreting repeat customers

**297 of 300** purchasing customers placed at least two completed orders in 2025, contributing **99.8%** of annual net sales. The measure includes their first order in the period. This unusually high share reflects the generated data and does not demonstrate retention, customer lifetime value or loyalty. No purchase history before 2025 is available. [Customer results](../analysis/customer_summary.csv).

## Validation and limits

The raw-to-clean reconciliation removes **46 exact duplicate rows** and rejects **7 invalid rows**. Returns are aggregated by line before joining financial detail to avoid multiplying sales. The annual total reconciles across line, order, month, region, product and category summaries. [Recorded checks](../checks/validation_results.json).

These findings are derived from the independently executed raw-CSV pipeline. The Excel file reproduces the financial totals with formulas. The prepared SQL Server solution still requires a successful execution on the target server. All records are fictional; no profit, target attainment or real-company recommendation is inferred.
