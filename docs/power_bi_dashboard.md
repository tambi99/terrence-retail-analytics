# Power BI Dashboard

This report extends the Harbor Home & Office retail analytics project with an interactive Power BI layer focused on executive sales performance and returns analysis.

## Report pages

### Executive Overview

The Executive Overview summarizes overall retail performance with KPI cards and trend visuals designed for quick management review.

Key areas include:

- Net Sales After Refunds
- Refund Amount
- Return Rate
- Monthly Net Sales trend
- Net Sales by Product Category
- Monthly performance comparison
- Calendar-based date filtering and Year-Month sorting

### Returns Analysis

The Returns Analysis page focuses on where refunds are occurring and what is driving them.

Key areas include:

- Refund Amount by Return Reason
- Top 10 Products by Refund Amount
- Return Rate by Product Category
- Return Reason distribution
- Refund trend analysis
- Product-level and category-level investigation

## Data model

The Power BI model uses the cleaned retail data produced earlier in the project. A dedicated Calendar table supports time-intelligence calculations and consistent month ordering.

Core business entities include:

- Customers
- Orders
- Order Items
- Products
- Returns
- Calendar

The model preserves the same analytical logic used in the Excel and SQL portions of the project so results remain comparable across tools.

## Selected DAX measures

The report uses measures for sales, refunds, return rates, and time intelligence. Representative measures include:

```DAX
Net Sales After Refunds =
[Net Sales Before Returns] - [Refund Amount]
```

```DAX
Return Rate =
DIVIDE(
    [Returned Units],
    [Units Sold],
    0
)
```

```DAX
Previous Month Net Sales =
CALCULATE(
    [Net Sales After Refunds],
    PREVIOUSMONTH('Calendar'[Date])
)
```

```DAX
Monthly Net Sales Growth % =
DIVIDE(
    [Net Sales After Refunds] - [Previous Month Net Sales],
    [Previous Month Net Sales],
    0
)
```

The model also includes ranking and Top N logic for identifying products with the largest refund impact.

## Reporting design decisions

The report separates sales performance from returns diagnostics so users can first understand the overall business position and then investigate refund drivers.

Month labels are sorted using a dedicated Year-Month sort field rather than alphabetical month order. Time-intelligence measures use the Calendar table rather than the raw order-date hierarchy.

Top-product refund analysis is based on refund amount rather than return count, which keeps the focus on financial impact.

## Skills demonstrated

- Power BI semantic modeling
- Data relationships
- DAX measures
- Time intelligence
- KPI design
- Top N analysis
- Business-focused dashboard design
- Returns and refund analysis
- Interactive filtering and drill-down analysis
- Cross-tool validation against Excel and SQL outputs

## Power BI file

The completed report is stored in the repository as:

`powerbi/Retail_Sales_Returns_Analytics.pbix`

Open the file in Power BI Desktop to explore the interactive report.
