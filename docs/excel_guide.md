# Excel project guide

## Portable analysis workbook

Open `excel/Terrence_Retail_Analysis.xlsx`. Dashboard is the portfolio view. Monthly calculates twelve month totals, growth, running sales and a trailing average. Orders has one row per clean order and rolls up line results. SalesLines holds prepared input fields and the financial calculation columns.

SalesLines columns A–L are a snapshot of accepted lines joined to order, customer and product attributes, plus accepted returns aggregated by line. Their source is `analysis/fact_order_lines.csv`, produced from the original five raw CSVs by `scripts/build_analysis.py`. Financial outputs in columns M–S are Excel formulas, not pasted KPI results. Orders A–F come from clean orders and customers; its remaining fields calculate from SalesLines. Summary formulas use the order grain for order counts.

Existing-row quantity, price, discount or return-unit edits recalculate line amounts, order totals, monthly results and charts. Such edits are experiments, not changes to the raw dataset. Restore them after practice. The supplied formula ranges cover this fixed dataset; adding rows or changing keys requires rebuilding and validating ranges. Inputs are already validated by the pipeline and are not a replacement for Power Query quality checks.

**Refresh boundary:** This file does not contain an automatic Power Query refresh connection. Rebuild the pipeline from raw CSVs, then update its prepared inputs and verify all checkpoints. `Refresh All` alone does not update these worksheet snapshots. Order formulas reference their assigned line cells; changing IDs, inserting or reordering source rows requires rebuilding those assignments. Quantity, price, discount and return-unit experiments on existing rows are supported.

`excel/Terrence_Power_Query_Practice.xlsx` preserves the original hands-on workbook byte for byte, including its Power Query content and Data Model. It contains five clean worksheet tables and the quality log. All counts match the independent pipeline. It retains 164 Web/Retail channel labels and sentence-case return reasons; mapping Web to Online, Retail to Store and normalizing reason capitalization yields matching business values in all five tables. The final analysis applies those normalizations. The saved practice file has no PivotTable parts or Calendar query, so the later in-session PivotTable work is not captured in that copy.

The original queries use local CSV paths from the practice session. Point their Source steps to this repository's `data/raw` files on your computer before refreshing. This source workbook remains evidence of the hands-on cleaning process; use the analysis workbook for the finished portfolio dashboard.

## Finish or repeat the hands-on Power Query model

These steps describe the practice workflow already followed during this project. They are also instructions for independently rebuilding it from `data/raw`.

1. Import each raw CSV as a connection-only query; preserve raw values and record the full source counts. Profile the **entire dataset**.
2. Reference each raw query for cleaning. Deduplicate exact rows and keep separate rejected queries with reasons. Apply the rules in `methodology.md`.
3. Use consistent validation text such as `Valid` and `Invalid`. `List.Contains` is case-sensitive by default: mixing lowercase `invalid` with `Invalid` can accidentally retain bad rows.
4. Check parent keys with merges; returns match `order_line_id` to **clean order lines**, not to Returns. Aggregate valid return quantities by line and compare with purchased quantity.
5. Load the five cleaned tables into the Data Model. Keep raw, rejected and intermediate queries as connections. The quality log is documentation, not a business relationship table.
6. Add the Calendar query below and relate Calendar.Date to clean Orders.order_date. Confirm each one-side key is unique before creating relationships.
7. Build a PivotTable with Customers.region in Rows, a **Distinct Count** of Orders.order_id in Values and Orders.status filtered to Completed. Total: **1,661**; West: **484**.

```powerquery
let
    Dates = List.Dates(#date(2025, 1, 1), 365, #duration(1, 0, 0, 0)),
    DateTable = Table.FromColumns({Dates}, type table [Date = date]),
    Year = Table.AddColumn(DateTable, "Year", each Date.Year([Date]), Int64.Type),
    MonthNumber = Table.AddColumn(Year, "MonthNumber", each Date.Month([Date]), Int64.Type),
    MonthName = Table.AddColumn(MonthNumber, "MonthName", each Date.ToText([Date], "MMM", "en-US"), type text),
    MonthStart = Table.AddColumn(MonthName, "MonthStart", each Date.StartOfMonth([Date]), type date)
in
    MonthStart
```

Use MonthStart for chronological monthly grouping. MonthName alone sorts alphabetically unless it is sorted by MonthNumber. Returns extend into 2026; this calendar supports original-order reporting, not refund-date reporting.

## Workbook verification

Compare the workbook totals with `analysis/summary.json` and the original PivotTable. Expected gross sales are $2,170,836.00; discounts $194,394.30; refunds $100,947.10; net sales $1,875,494.60. A temporary $10 increase to the first line's unit price must increase net sales by $8; restoring the input must restore the original total. The first line has one sold unit, no returns and a 20% discount.

The portable workbook has been recalculated by Artifact Tool. The original practice workbook's byte-for-byte preservation, native parts and clean business values have been inspected. Desktop Excel refresh and execution have not been verified. Do not infer Data Model or Power Query connectivity in the portable analysis file from the presence of a dashboard image.
