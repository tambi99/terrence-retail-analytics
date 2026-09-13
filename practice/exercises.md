# Short practice exercises

Work in a copy. Attempt each exercise before opening the solution or checkpoint. This is a compact route through the skills, not a requirement to redo every step before using the portfolio.

1. **Cleaning:** Explain why the `-2` quantity should be rejected and why missing email is allowed. Find the error caused by comparing lowercase `invalid` with `Invalid`.
2. **Grain:** Explain why Returns needs `return_id`, and why joining raw return events directly to order lines can overstate revenue.
3. **Excel model:** Rebuild the region PivotTable with a distinct order count and Completed filter. Check 1,661 total and 484 West orders.
4. **Excel formulas:** Change the first line's unit price from 211 to 221. Predict the net sales change, verify it, and restore 211. Trace the affected order and month.
5. **CTEs:** Write annual gross sales, discounts, refunds and net sales as readable CTEs. Count orders from the order grain.
6. **Window functions:** Produce monthly growth with `LAG`, running net sales with `SUM OVER`, a three-month moving average with a `ROWS` frame, and top products per category with `DENSE_RANK`.
7. **Interpretation:** Explain why West leading order volume does not mean it has the highest AOV. Explain why the Store return-rate difference does not establish a cause.

Completed SQL solutions are in `sql/04_analysis.sql`. See `checks/expected_checkpoints.json` for answers. The first-line Excel experiment changes net sales by **$8** because one unit has a 20% discount and no return.

## Five interview explanations

- How did you reconcile every source row after cleaning?
- What is the grain of each table, and where can double-counting occur?
- How do a CTE and a window function serve different purposes?
- Why are cancelled orders retained in the model but excluded from KPIs?
- Why are a ratio of totals and an average of row percentages different?

Add a sentence in your own words for each answer before presenting this project.
