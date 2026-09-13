# Run the completed SQL Server portfolio

The five SQL files contain the complete solution. They target **SQL Server 2017 or later on Windows**, with database compatibility level 130 or higher and SSMS. SQL Server execution has **not** been verified in the authoring environment. Run the assertions below on your instance before describing the SQL results as executed. The included financial checkpoints were independently derived from the CSV data.

## Prepare the import

1. In SSMS, select a dedicated user database for this portfolio. The scripts do not create, drop, or alter databases. They own only the `retail_stg`, `retail`, and `retail_audit` schemas; use those names exclusively for this project.
2. From the repository root, run the helper in PowerShell:

   ```powershell
   .\sql\prepare_import.ps1 -RawFolder '.\data\raw' -OutputFolder '.\data\sql_import'
   ```

   This creates separate UTF-8 CSVs with an added `source_row` column. All original field values remain text, including spaces, dollar signs, percentages and invalid dates. The header is row 1, and the first data record is row 2, matching the Python audit. The original CSVs are unchanged. A logical CSV record is the unit of numbering, even when quoted fields contain newlines.

3. Place the resulting `data/sql_import` folder somewhere the SQL Server service can read. If SQL Server runs on another computer, copy the numbered files to that computer or an approved share. In `02_import.sql`, set the single `@ImportFolder` value to that **server-side** absolute folder. The default is an illustrative path, not a path to a supplied machine.
4. Your SQL login needs permission to create these schema objects and run `BULK INSERT`; SQL Server also needs file read access. Use your existing approved account and location. `TRY_PARSE` uses SQL Server's .NET runtime with an explicit `en-US` culture. No credentials or connection strings belong in the repository.

The helper uses Windows PowerShell 5.1 or newer. Its output is fully quoted UTF-8 without a BOM, with LF line endings matching the import options. Staging fields are `nvarchar(200)` because this fixed dataset's original fields fit that bound; a different dataset with larger fields requires an explicit schema change. CSV empty fields can import as SQL `NULL`; normalization treats empty text as missing. The source CSV remains the definitive byte-for-byte record.

## Run in order

Open each file in SSMS, confirm the selected database, and execute the entire file. Stop on any error and resolve it before continuing.

| File | Result |
|---|---|
| `sql/01_schema.sql` | All-text staging, typed tables, calendar structure, parsing functions, and reusable sales/audit views. Existing tables retain their data. |
| `sql/02_import.sql` | Atomic replacement of the five staging tables from the numbered CSVs. Expected raw counts: 304, 26, 1,813, 4,476, 339. |
| `sql/03_clean_load.sql` | Exact duplicate removal, conflicting-key quarantine, validation in parent-before-child order, daily calendar, typed data and record-level audit. |
| `sql/04_analysis.sql` | Annual KPIs, all 12 months, growth, running sales, moving average, category/product/channel comparisons, repeat customers and order sequence. |
| `sql/05_validation.sql` | Raises an error for any failed benchmark or integrity assertion; reports the server version and timestamp only after all checks pass. |

For a scripted run, use your existing `sqlcmd` connection options with `-b` so execution stops on errors. The files use `GO` batch separators and must be run by SSMS, `sqlcmd`, or another client that understands those separators.

## Reload and audit behavior

Rerun `02`, `03`, and `05` against the same files. The counts and metrics must stay identical. Import and clean loading each use `XACT_ABORT`, `TRY/CATCH`, a transaction and the same exclusive application lock. A failing operation rolls back its own changes. The clean load replaces only its owned model and audit rows, in foreign-key-safe order, and preserves staging. The last successful import and the clean load are separate transactions: run `03` immediately after `02`, then validate before using the refreshed results. Avoid concurrent analysis during a reload.

`retail_audit.Disposition` records one status for every source record: Accepted, Duplicate or Rejected. It keeps the source file label, stable record number, business key, original business values as JSON, reason and, for duplicates, the retained record number. The audit reflects the current load; it is not a historical archive. Duplicate comparison uses every original business field, excludes `source_row`, and uses binary collation on the JSON representation. After exact duplicates are removed, all differing records that share a normalized key are quarantined for review. Different order lines with the same order/product pair remain separate.

Return validation first removes individually invalid events. The deliberately bad `RX001` has 999 units and shares a line with valid `R00001`; `R00001` survives. Only otherwise-valid events enter cumulative validation. If those events collectively exceed purchased units, all remaining events on that line are quarantined for review. Foreign keys and table checks enforce local rules; the loader and validation script enforce cross-table date, status and cumulative rules. Direct manual writes bypass the loader's checks and require revalidation.

## Expected verification

| Source | Raw | Accepted | Exact duplicates removed | Rejected |
|---|---:|---:|---:|---:|
| Customers | 304 | 300 | 4 | 0 |
| Products | 26 | 24 | 2 | 0 |
| Orders | 1,813 | 1,800 | 12 | 1 |
| Order lines | 4,476 | 4,446 | 25 | 5 |
| Returns | 339 | 335 | 3 | 1 |

The rejected IDs are `OX0001`, `X000001`–`X000005`, and `RX001`. The model retains 139 cancelled orders and their valid lines, while every sales and customer KPI uses the 1,661 completed orders. The calendar contains all 365 dates in 2025. Returns through **January 30, 2026** attach to their original **2025 order month**. USD only; taxes, shipping and costs are absent.

| KPI | Expected |
|---|---:|
| Gross sales | $2,170,836.00 |
| Discounts | $194,394.30 |
| Sales before returns | $1,976,441.70 |
| Refunds | $100,947.10 |
| Net sales | $1,875,494.60 |
| Completed orders | 1,661 |
| Net AOV | $1,129.14 |
| Sold units | 12,354 |
| Returned units | 648 |
| Unit return rate | 5.2453% |

The views retain six decimal places for amounts; display rounding does not change calculations. `vLineSales` has one row per completed line after returns are aggregated by line. `vOrderSales` has one row per completed order. Category order counts overlap and should not be added. Repeat-customer sales share includes all 2025 sales from customers with at least two completed orders; it does not measure retention or customer history before 2025.

Save the final validation result, your server version and a second successful reload result as execution evidence. Until then, distinguish **prepared SQL** from the independently calculated dataset benchmarks.

Microsoft references: [BULK INSERT CSV and UTF-8 options](https://learn.microsoft.com/en-us/sql/t-sql/statements/bulk-insert-transact-sql), [TRY_PARSE and explicit culture](https://learn.microsoft.com/en-us/sql/t-sql/functions/try-parse-transact-sql), [window functions and ROWS frames](https://learn.microsoft.com/en-us/sql/t-sql/queries/select-over-clause-transact-sql).

The import helper uses [.NET TextFieldParser with TrimWhiteSpace disabled](https://learn.microsoft.com/en-us/dotnet/api/microsoft.visualbasic.fileio.textfieldparser.trimwhitespace) so source whitespace survives the numbered import files. Field-by-field comparison against all raw records passed; see `checks/sql_import_fidelity.json`.
