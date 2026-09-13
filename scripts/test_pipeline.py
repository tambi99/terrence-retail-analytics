"""Meaningful contract regressions: python -m unittest discover -s scripts -p 'test_*.py'."""
import contextlib
import hashlib
import io
import json
import shutil
import tempfile
import unittest
from datetime import date
from decimal import Decimal as D
from pathlib import Path

from build_analysis import BASE, SCHEMAS, build_facts, clean_table, parse_date, parse_decimal, parse_quantity, run


def raw(source_row=2, **fields):
    return {**fields, "source_row": source_row}


class CleaningContractTests(unittest.TestCase):
    def setUp(self):
        self.customer = {"customer_id": "C0001", "customer_name": "Example", "region": "East", "segment": "Consumer", "email": None, "source_row": 2}
        self.product = {"product_id": "P001", "product_name": "Example", "category": "Furniture", "list_price": D("100"), "source_row": 2}
        self.order = {"order_id": "O00001", "customer_id": "C0001", "order_date": date(2025, 1, 15), "channel": "Online", "status": "Completed", "source_row": 2}
        self.line = {"order_line_id": "L000001", "order_id": "O00001", "product_id": "P001", "quantity": 5, "unit_price": D("100"), "discount_rate": D("0.1"), "source_row": 2}
        self.parents = {"customers": {"C0001": self.customer}, "products": {"P001": self.product}, "orders": {"O00001": self.order}, "order_lines": {"L000001": self.line}}

    def event(self, return_id, quantity, source_row=2, return_date="2025-02-01"):
        return raw(source_row, return_id=return_id, order_line_id="L000001", return_date=return_date, return_quantity=str(quantity), reason="Damaged")

    def test_dates_are_explicitly_us_and_impossible_dates_rejected(self):
        self.assertEqual(parse_date("02/03/2025"), date(2025, 2, 3))
        self.assertEqual(parse_date("2025-02-03"), date(2025, 2, 3))
        for value in ("13/02/2025", "2025-02-30", "03-Feb-2025"):
            with self.assertRaises(ValueError):
                parse_date(value)

    def test_fraction_percent_and_us_currency_parsing(self):
        self.assertEqual(parse_decimal("20%", percent=True), D(".20"))
        self.assertEqual(parse_decimal("0.20", percent=True), D(".20"))
        self.assertEqual(parse_decimal("$1,234.50", currency=True), D("1234.50"))
        for value in ("1,23.50", "NaN", "unknown"):
            with self.assertRaises(ValueError):
                parse_decimal(value, currency=True)

    def test_quantities_must_be_positive_integers(self):
        self.assertEqual(parse_quantity("2.0"), 2)
        for value in ("0", "-2", "2.5"):
            with self.assertRaises(ValueError):
                parse_quantity(value)

    def test_duplicate_ignores_source_row_and_allows_missing_email(self):
        one = raw(customer_id="C0001", customer_name="Example", region=" east ", segment="CONSUMER", email="")
        two = {**one, "source_row": 3}
        clean, rejected, duplicates = clean_table("customers", [one, two], {})
        self.assertEqual((len(clean), len(rejected), len(duplicates)), (1, 0, 1))
        self.assertIsNone(clean[0]["email"])
        self.assertEqual(clean[0]["region"], "East")

    def test_conflicting_keys_quarantine_all_values(self):
        one = raw(customer_id="C0001", customer_name="First", region="East", segment="Consumer", email="")
        two = {**one, "customer_name": "Different", "source_row": 3}
        clean, rejected, duplicates = clean_table("customers", [one, two], {})
        self.assertEqual((len(clean), len(rejected), len(duplicates)), (0, 2, 0))
        self.assertTrue(all("conflicting" in row["rejection_reason"] for row in rejected))

    def test_distinct_lines_with_same_order_product_are_not_duplicates(self):
        one = raw(**{key: str(value) for key, value in self.line.items() if key != "source_row"})
        two = {**one, "order_line_id": "L000002", "source_row": 3}
        clean, rejected, duplicates = clean_table("order_lines", [one, two], self.parents)
        self.assertEqual((len(clean), len(rejected), len(duplicates)), (2, 0, 0))

    def test_unknown_parent_is_rejected(self):
        line = raw(**{key: str(value) for key, value in self.line.items() if key != "source_row"})
        line["order_id"] = "O99999"
        clean, rejected, _ = clean_table("order_lines", [line], self.parents)
        self.assertEqual(len(clean), 0)
        self.assertIn("unknown or rejected order", rejected[0]["rejection_reason"])

    def test_invalid_large_event_does_not_discard_legitimate_same_line_return(self):
        clean, rejected, _ = clean_table("returns", [self.event("R00001", 2), self.event("R00002", 999, 3)], self.parents)
        self.assertEqual([row["return_id"] for row in clean], ["R00001"])
        self.assertIn("event exceeds purchased quantity", rejected[0]["rejection_reason"])

    def test_cumulative_excess_quarantines_entire_otherwise_valid_group(self):
        clean, rejected, _ = clean_table("returns", [self.event("R00001", 3), self.event("R00002", 3, 3)], self.parents)
        self.assertEqual(len(clean), 0)
        self.assertEqual(len(rejected), 2)
        self.assertTrue(all("cumulative" in row["rejection_reason"] for row in rejected))

    def test_multiple_valid_returns_do_not_expand_line_join(self):
        returns, _, _ = clean_table("returns", [self.event("R00001", 2), self.event("R00002", 1, 3)], self.parents)
        clean = {key: list(value.values()) for key, value in self.parents.items()}
        facts = build_facts({**clean, "returns": returns})
        self.assertEqual(len(facts), 1)
        self.assertEqual(facts[0]["returned_units"], 3)
        self.assertEqual(facts[0]["net_sales"], D("180"))
        self.assertEqual(facts[0]["order_month"], "2025-01")

    def test_return_date_bounds_and_cancelled_order_returns(self):
        clean, rejected, _ = clean_table("returns", [self.event("R00001", 1, return_date="2025-01-14"), self.event("R00002", 1, 3, "2026-01-31")], self.parents)
        self.assertEqual((len(clean), len(rejected)), (0, 2))
        self.order["status"] = "Cancelled"
        clean, rejected, _ = clean_table("returns", [self.event("R00003", 1)], self.parents)
        self.assertEqual(len(clean), 0)
        self.assertIn("requires completed", rejected[0]["rejection_reason"])

    def test_cancelled_orders_and_lines_stay_clean_but_kpi_flag_false(self):
        order = raw(**{key: str(value) for key, value in self.order.items() if key != "source_row"})
        order["status"] = "Cancelled"
        clean_orders, rejected, _ = clean_table("orders", [order], self.parents)
        self.assertEqual((len(clean_orders), len(rejected)), (1, 0))
        clean = {key: list(value.values()) for key, value in self.parents.items()}
        clean["orders"] = clean_orders
        facts = build_facts({**clean, "returns": []})
        self.assertEqual(len(facts), 1)
        self.assertFalse(facts[0]["include_in_sales_kpi"])


class EndToEndTests(unittest.TestCase):
    def test_reproducible_raw_derived_output_and_benchmark_disagreement_fails(self):
        with tempfile.TemporaryDirectory(prefix="retail_validation_") as folder:
            base = Path(folder)
            shutil.copytree(BASE / "data" / "raw", base / "data" / "raw")
            (base / "checks").mkdir()
            shutil.copyfile(BASE / "checks" / "expected_checkpoints.json", base / "checks" / "expected_checkpoints.json")
            raw_before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (base / "data" / "raw").glob("*.csv")}
            with contextlib.redirect_stdout(io.StringIO()):
                run(base)
                first = (base / "analysis" / "summary.json").read_bytes()
                run(base)
            self.assertEqual(first, (base / "analysis" / "summary.json").read_bytes())
            raw_after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (base / "data" / "raw").glob("*.csv")}
            self.assertEqual(raw_before, raw_after)
            expected_path = base / "checks" / "expected_checkpoints.json"
            expected = json.loads(expected_path.read_text())
            expected["net_sales"] = "1.00"
            expected_path.write_text(json.dumps(expected))
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(AssertionError, "benchmark_net_sales"):
                run(base)


if __name__ == "__main__":
    unittest.main(verbosity=2)
