# Verification evidence

- `source_manifest.json`: SHA-256 hashes and raw source counts.
- `validation_results.json`: 31 executed checks covering row accounting, unique keys, relationships, return rules, financial identities and aggregation reconciliations.
- `expected_checkpoints.json`: fixed-dataset test targets, kept outside the calculation path.
- `excel_validation.json`: formula totals and a restored input-change test executed with Artifact Tool. This is not evidence of native desktop Excel execution.
- `original_workbook_validation.json`: original workbook preservation, native feature inventory and comparison of all five clean tables. Remaining label normalizations are documented in the Excel guide.
- `sql_import_fidelity.json`: helper-generated import records compared field by field with every raw CSV record, including original whitespace and stable row numbers.

The independent Python pipeline and all 13 tests in `scripts/test_pipeline.py` passed during portfolio preparation. The tests include duplicate conflicts, malformed values, cancelled orders, cumulative returns, join grain, source immutability and reproducibility. A deliberately changed benchmark correctly causes the pipeline to fail.

SQL execution remains **unverified**. SQL Server was present locally, but the client failed to establish a connection with `SSL Provider: No credentials are available in the security package`. No database was created or changed. Follow `docs/sql_setup.md` and retain the output of `sql/05_validation.sql`, then repeat the import/clean/validate cycle to prove rerun stability on your server.

The three engines share the same source dataset and metric definitions. Prepared SQL text and matching independently calculated benchmarks do not establish that the SQL scripts have run.
