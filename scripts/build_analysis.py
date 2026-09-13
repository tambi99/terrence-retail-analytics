"""Rebuild synthetic retail clean data, cohort analysis, and reconciliation.

Run from any directory with Python 3.10+: python scripts/build_analysis.py
Uses only the Python standard library. Raw CSVs are inputs, never generated truth.
Currency uses Decimal throughout; CSV output retains the available precision.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
D = Decimal
ZERO = D(0)
SCHEMAS = {
    "customers": ["customer_id", "customer_name", "region", "segment", "email"],
    "products": ["product_id", "product_name", "category", "list_price"],
    "orders": ["order_id", "customer_id", "order_date", "channel", "status"],
    "order_lines": ["order_line_id", "order_id", "product_id", "quantity", "unit_price", "discount_rate"],
    "returns": ["return_id", "order_line_id", "return_date", "return_quantity", "reason"],
}
KEY_LENGTHS = {"customer_id": 5, "product_id": 4, "order_id": 6, "order_line_id": 7, "return_id": 6}
MEASURES = ["gross_sales", "discounts", "sales_before_returns", "refunds", "net_sales", "sold_units", "returned_units"]


def parse_date(value: str) -> date:
    value = value.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return datetime.strptime(value, "%Y-%m-%d").date()
    if re.fullmatch(r"\d{2}/\d{2}/\d{4}", value):
        return datetime.strptime(value, "%m/%d/%Y").date()
    raise ValueError("date must be ISO YYYY-MM-DD or US MM/DD/YYYY")


def parse_decimal(value: str, *, percent: bool = False, currency: bool = False) -> Decimal:
    text = value.strip()
    divisor = D(100) if percent and text.endswith("%") else D(1)
    if divisor == 100:
        text = text[:-1].strip()
    if currency:
        text = text.removeprefix("$").strip()
    if not re.fullmatch(r"[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?", text):
        raise ValueError("invalid US-locale decimal")
    number = D(text.replace(",", "")) / divisor
    if not number.is_finite():
        raise ValueError("nonfinite decimal")
    return number


def parse_quantity(value: str) -> int:
    number = parse_decimal(value)
    if number <= 0 or number != number.to_integral_value():
        raise ValueError("quantity must be a positive integer")
    return int(number)


def normalize(table: str, raw: dict) -> tuple[dict, list[str]]:
    result, reasons = {}, []
    for field in SCHEMAS[table]:
        value = (raw.get(field) or "").strip()
        if not value and field != "email":
            reasons.append(f"{field}: required field missing")
        try:
            if field.endswith("_id"):
                value = value.upper()
                if len(value) != KEY_LENGTHS[field] or not value.isalnum():
                    reasons.append(f"{field}: invalid text identifier")
            elif field.endswith("_date"):
                value = parse_date(value)
            elif field in ("unit_price", "list_price"):
                value = parse_decimal(value, currency=True)
                if value <= 0:
                    reasons.append(f"{field}: price must be positive")
            elif field == "discount_rate":
                value = parse_decimal(value, percent=True)
                if not ZERO <= value <= 1:
                    reasons.append("discount_rate: outside [0,1]")
            elif field in ("quantity", "return_quantity"):
                value = parse_quantity(value)
            elif field == "channel":
                value = {"web": "Online", "online": "Online", "retail": "Store", "store": "Store"}.get(value.casefold(), value.title())
            elif field in ("region", "segment", "category", "status", "reason"):
                value = value.title()
            elif field == "email":
                value = value.lower() or None
        except (ValueError, InvalidOperation) as error:
            reasons.append(f"{field}: {error}")
        result[field] = value
    for field, domain in {"region": {"North", "South", "East", "West"}, "segment": {"Consumer", "Business"}, "channel": {"Online", "Store"}, "status": {"Completed", "Cancelled"}}.items():
        if field in result and result[field] not in domain:
            reasons.append(f"{field}: unrecognized value")
    if table == "orders" and isinstance(result["order_date"], date) and result["order_date"].year != 2025:
        reasons.append("order_date: outside 2025")
    result["source_row"] = raw["source_row"]
    return result, reasons


def clean_table(table: str, raw_rows: list[dict], parents: dict) -> tuple[list, list, list]:
    """Deduplicate canonical business fields; quarantine all conflicting key values.

    Return errors are checked individually first, including event quantity > sold.
    Only otherwise valid events enter the cumulative per-line bound check.
    If those still exceed the purchase, the entire conflicting group is rejected.
    """
    prepared, rejected, duplicates, seen = [], [], [], set()
    for raw in raw_rows:
        row, reasons = normalize(table, raw)
        fingerprint = tuple(row[field] for field in SCHEMAS[table])
        if fingerprint in seen:
            duplicates.append({**raw, "rejection_reason": "duplicate business record (source row excluded)"})
            continue
        seen.add(fingerprint)
        prepared.append((raw, row, reasons))
    key_field = SCHEMAS[table][0]
    key_counts = Counter(row[key_field] for _, row, _ in prepared)
    candidates = []
    for raw, row, reasons in prepared:
        if key_counts[row[key_field]] > 1:
            reasons.append(f"{key_field}: conflicting business records for key")
        if table == "orders" and row["customer_id"] not in parents["customers"]:
            reasons.append("customer_id: unknown or rejected customer")
        if table == "order_lines":
            if row["order_id"] not in parents["orders"]:
                reasons.append("order_id: unknown or rejected order")
            if row["product_id"] not in parents["products"]:
                reasons.append("product_id: unknown or rejected product")
        if table == "returns":
            line = parents["order_lines"].get(row["order_line_id"])
            if line is None:
                reasons.append("order_line_id: unknown or rejected line")
            else:
                order = parents["orders"][line["order_id"]]
                if order["status"] != "Completed":
                    reasons.append("order_id: return requires completed order")
                if isinstance(row["return_date"], date):
                    if row["return_date"] < order["order_date"]:
                        reasons.append("return_date: precedes order date")
                    if row["return_date"] > date(2026, 1, 30):
                        reasons.append("return_date: after 2026-01-30 cutoff")
                if isinstance(row["return_quantity"], int) and row["return_quantity"] > line["quantity"]:
                    reasons.append("return_quantity: event exceeds purchased quantity")
        if reasons:
            rejected.append({**raw, "rejection_reason": "; ".join(reasons)})
        else:
            candidates.append((raw, row))
    if table == "returns":
        cumulative = Counter()
        for _, row in candidates:
            cumulative[row["order_line_id"]] += row["return_quantity"]
        excessive = {key for key, qty in cumulative.items() if qty > parents["order_lines"][key]["quantity"]}
        accepted = []
        for raw, row in candidates:
            if row["order_line_id"] in excessive:
                rejected.append({**raw, "rejection_reason": "return_quantity: cumulative valid events exceed purchased quantity; whole group quarantined"})
            else:
                accepted.append(row)
    else:
        accepted = [row for _, row in candidates]
    return accepted, rejected, duplicates


def json_default(value):
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, date):
        return value.isoformat()
    raise TypeError(type(value).__name__)


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, default=json_default, allow_nan=False) + "\n", encoding="utf-8")


def write_csv(path: Path, rows: list[dict], fields=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = fields or (list(rows[0]) if rows else [])
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def read_csv(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8-sig") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != SCHEMAS[path.stem]:
            raise ValueError(f"Unexpected schema in {path.name}: {reader.fieldnames}")
        return [{**row, "source_row": row_number} for row_number, row in enumerate(reader, 2)]


def total(rows: list[dict]) -> dict:
    metrics = {key: sum((row[key] for row in rows), ZERO if key not in ("sold_units", "returned_units") else 0) for key in MEASURES}
    metrics["completed_orders"] = len({row["order_id"] for row in rows})
    metrics["purchasing_customers"] = len({row["customer_id"] for row in rows})
    metrics["aov"] = metrics["net_sales"] / metrics["completed_orders"] if metrics["completed_orders"] else None
    metrics["unit_return_rate"] = D(metrics["returned_units"]) / metrics["sold_units"] if metrics["sold_units"] else None
    return metrics


def group_summary(rows: list[dict], field: str, extras: tuple = ()) -> list[dict]:
    groups = defaultdict(list)
    for row in rows:
        groups[row[field]].append(row)
    result = []
    grand_net = sum((row["net_sales"] for row in rows), ZERO)
    for key in sorted(groups):
        group = groups[key]
        metrics = total(group)
        result.append({field: key, **{extra: group[0][extra] for extra in extras}, **metrics, "net_sales_share": metrics["net_sales"] / grand_net if grand_net else None})
    return result


def build_facts(clean: dict) -> list[dict]:
    customers = {row["customer_id"]: row for row in clean["customers"]}
    products = {row["product_id"]: row for row in clean["products"]}
    orders = {row["order_id"]: row for row in clean["orders"]}
    returns = defaultdict(list)
    for event in clean["returns"]:
        returns[event["order_line_id"]].append(event)
    facts = []
    for line in clean["order_lines"]:
        order, product = orders[line["order_id"]], products[line["product_id"]]
        customer = customers[order["customer_id"]]
        events = returns[line["order_line_id"]]
        returned = sum(event["return_quantity"] for event in events)
        gross = line["quantity"] * line["unit_price"]
        discount = gross * line["discount_rate"]
        refund = returned * line["unit_price"] * (1 - line["discount_rate"])
        facts.append({
            "order_line_id": line["order_line_id"], "order_id": order["order_id"], "customer_id": customer["customer_id"],
            "customer_name": customer["customer_name"], "region": customer["region"], "segment": customer["segment"], "email": customer["email"],
            "order_date": order["order_date"], "order_month": order["order_date"].strftime("%Y-%m"), "channel": order["channel"], "status": order["status"],
            "include_in_sales_kpi": order["status"] == "Completed", "product_id": product["product_id"], "product_name": product["product_name"], "category": product["category"], "list_price": product["list_price"],
            "quantity": line["quantity"], "unit_price": line["unit_price"], "discount_rate": line["discount_rate"], "return_events": len(events),
            "latest_return_date": max((event["return_date"] for event in events), default=None), "gross_sales": gross, "discounts": discount,
            "sales_before_returns": gross-discount, "refunds": refund, "net_sales": gross-discount-refund,
            "sold_units": line["quantity"], "returned_units": returned, "line_source_row": line["source_row"],
            "order_source_row": order["source_row"], "customer_source_row": customer["source_row"], "product_source_row": product["source_row"],
        })
    return facts


def run(base: Path = BASE) -> dict:
    clean, parents, quality, source_manifest = {}, {}, [], []
    for table in SCHEMAS:
        path = base / "data" / "raw" / f"{table}.csv"
        raw = read_csv(path)
        accepted, rejected, duplicates = clean_table(table, raw, parents)
        clean[table] = accepted
        parents[table] = {row[SCHEMAS[table][0]]: row for row in accepted}
        write_csv(base / "data" / "clean" / f"{table}.csv", accepted, SCHEMAS[table] + ["source_row"])
        write_csv(base / "data" / "rejected" / f"{table}.csv", rejected, SCHEMAS[table] + ["source_row", "rejection_reason"])
        write_csv(base / "data" / "rejected" / f"duplicates_{table}.csv", duplicates, SCHEMAS[table] + ["source_row", "rejection_reason"])
        quality.append({"table": table, "raw_rows": len(raw), "duplicate_rows_removed": len(duplicates), "rejected_rows": len(rejected), "clean_rows": len(accepted), "accounting_passed": len(raw) == len(duplicates) + len(rejected) + len(accepted)})
        source_manifest.append({"path": f"data/raw/{table}.csv", "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size, "raw_rows": len(raw), "columns": SCHEMAS[table]})
    facts = build_facts(clean)
    sales = [row for row in facts if row["include_in_sales_kpi"]]
    kpis = total(sales)
    orders = group_summary(sales, "order_id", ("customer_id", "order_date", "order_month", "channel", "region", "segment"))
    categories = group_summary(sales, "category")
    products = group_summary(sales, "product_id", ("product_name", "category"))
    ranks = {value: rank for rank, value in enumerate(sorted({p["net_sales"] for p in products}, reverse=True), 1)}
    for row in products:
        row["net_sales_rank"] = ranks[row["net_sales"]]
    products.sort(key=lambda row: (row["net_sales_rank"], row["product_id"]))
    channels = group_summary(sales, "channel")
    regions = group_summary(sales, "region")
    active_customer_summary = {row["customer_id"]: row for row in group_summary(sales, "customer_id", ("customer_name", "region", "segment"))}
    customers = []
    for customer in clean["customers"]:
        row = active_customer_summary.get(customer["customer_id"], {"customer_id": customer["customer_id"], "customer_name": customer["customer_name"], "region": customer["region"], "segment": customer["segment"], **total([]), "net_sales_share": ZERO})
        row["is_repeat_customer"] = row["completed_orders"] >= 2
        customers.append(row)
    repeats = [row for row in customers if row["is_repeat_customer"]]
    kpis.update({"repeat_customers": len(repeats), "repeat_customer_rate": D(len(repeats)) / kpis["purchasing_customers"] if kpis["purchasing_customers"] else None,
                 "repeat_customer_net_sales": sum((row["net_sales"] for row in repeats), ZERO),
                 "cancelled_orders_excluded": sum(row["status"] == "Cancelled" for row in clean["orders"]), "cancelled_lines_excluded": len(facts)-len(sales)})
    kpis["repeat_sales_share"] = kpis["repeat_customer_net_sales"] / kpis["net_sales"] if kpis["net_sales"] else None
    by_month = {row["order_month"]: row for row in group_summary(sales, "order_month")}
    monthly = []
    for month in range(1, 13):
        key = f"2025-{month:02d}"
        row = by_month.get(key, {"order_month": key, **total([]), "net_sales_share": ZERO})
        previous = monthly[-1]["net_sales"] if monthly else None
        row["mom_growth"] = (row["net_sales"] - previous) / previous if previous else None
        row["trailing_3_month_avg"] = (monthly[-2]["net_sales"] + monthly[-1]["net_sales"] + row["net_sales"]) / 3 if len(monthly) >= 2 else None
        monthly.append(row)
    analysis = {"fact_order_lines": facts, "sales_fact_completed": sales, "order_summary": orders, "monthly_summary": monthly, "category_summary": categories, "product_summary": products, "channel_summary": channels, "region_summary": regions, "customer_summary": customers, "quality_summary": quality}
    for name, rows in analysis.items():
        write_csv(base / "analysis" / f"{name}.csv", rows)
    checks = []
    def check(name, passed, detail):
        checks.append({"check": name, "passed": bool(passed), "detail": detail})
    for table in SCHEMAS:
        key = SCHEMAS[table][0]
        check(f"unique_{table}_keys", len(clean[table]) == len({row[key] for row in clean[table]}), f"{len(clean[table])} clean rows")
    check("raw_row_accounting", all(row["accounting_passed"] for row in quality), "raw = clean + duplicates removed + invalid rows rejected, for every table")
    check("no_fact_join_fanout", len(facts) == len(clean["order_lines"]), f"{len(facts)} joined facts / {len(clean['order_lines'])} clean lines")
    check("completed_orders_have_lines", {row["order_id"] for row in clean["orders"] if row["status"] == "Completed"} == {row["order_id"] for row in sales}, "Completed order count is independently reconciled to clean order headers")
    check("all_foreign_keys_valid", all(row["customer_id"] in parents["customers"] for row in clean["orders"]) and all(row["order_id"] in parents["orders"] and row["product_id"] in parents["products"] for row in clean["order_lines"]) and all(row["order_line_id"] in parents["order_lines"] for row in clean["returns"]), "Dimensions validated before facts; rejected-parent children excluded")
    check("cumulative_return_quantity_bounded", all(0 <= row["returned_units"] <= row["quantity"] for row in facts), "Returns aggregated to line before joining")
    check("return_quantities_reconcile", sum(row["return_quantity"] for row in clean["returns"]) == kpis["returned_units"], "Accepted events equal line-level returned units")
    check("line_sales_identity", all(row["gross_sales"] - row["discounts"] - row["refunds"] == row["net_sales"] for row in facts), "Exact Decimal comparisons")
    check("monthly_calendar_complete", [row["order_month"] for row in monthly] == [f"2025-{i:02d}" for i in range(1, 13)], "All 12 calendar months appear")
    for name in ("order_summary", "monthly_summary", "category_summary", "product_summary", "channel_summary", "region_summary", "customer_summary"):
        check(f"reconcile_{name}", all(sum((row[key] for row in analysis[name]), ZERO) == kpis[key] for key in MEASURES), "All additive measures reconcile to completed-line totals; grouped distinct order counts are not additive across categories/products")
    expected = json.loads((base / "checks" / "expected_checkpoints.json").read_text(encoding="utf-8-sig"))
    for key in ("clean_rows", "duplicate_rows_removed", "rejected_rows"):
        actual = {row["table"]: row[key] for row in quality}
        check(f"benchmark_{key}", actual == expected[key], {"actual": actual, "expected": expected[key]})
    for key in ("completed_orders", "gross_sales", "discounts", "refunds", "net_sales", "sold_units", "returned_units", "aov"):
        check(f"benchmark_{key}", D(kpis[key]) == D(expected[key]), {"actual": str(kpis[key]), "expected": str(expected[key])})
    success = all(check["passed"] for check in checks)
    highest = max(monthly, key=lambda row: row["net_sales"])
    lowest = min(monthly, key=lambda row: row["net_sales"])
    top_category = max(categories, key=lambda row: row["net_sales"])
    return_category = max(categories, key=lambda row: row["unit_return_rate"] or ZERO)
    top_channel = max(channels, key=lambda row: row["net_sales"])
    top_region = max(regions, key=lambda row: row["net_sales"])
    summary = {
        "dataset": "Synthetic Terrence retail portfolio; no real customers or company results", "analysis_period": "2025-01-01 through 2025-12-31 completed order cohorts", "return_cutoff": "2026-01-30", "currency": "USD",
        "method": "Read raw CSV -> normalize -> deduplicate -> quarantine invalid/conflicting rows -> validate foreign keys -> aggregate returns by line -> join dimensions -> filter completed orders -> summarize with Decimal arithmetic",
        "kpis": kpis, "quality": quality, "validation_passed": success,
        "findings": {"peak_month": highest, "lowest_month": lowest, "top_category": top_category, "highest_return_rate_category": return_category, "top_products": [row for row in products if row["net_sales_rank"] <= 5], "top_channel": top_channel, "top_region": top_region},
        "limitations": ["Synthetic sample supports a portfolio demonstration, not a real business decision.", "Returns are attributed to original order month, including accepted events through January 30, 2026.", "Repeat customer means at least two completed orders in 2025; it is not retention and uses no earlier purchase history.", "No costs, profit, inventory, targets, campaign data or prior-year data were supplied; do not infer margin, causality, target attainment or year-over-year growth.", "Three-month average requires a full three-month calendar window; January and February are blank.", "Distinct order counts by product/category overlap and must not be summed across these groups.", "Known benchmark is generator-derived and only a comparison; clean outputs and measurements are independently computed from raw files."],
        "sources": source_manifest,
    }
    write_json(base / "analysis" / "summary.json", summary)
    write_json(base / "checks" / "source_manifest.json", {"dataset_type": "synthetic", "hash_algorithm": "SHA-256", "sources": source_manifest})
    write_json(base / "checks" / "validation_results.json", {"passed": success, "checks_count": len(checks), "checks": checks})
    print(json.dumps({"passed": success, "checks": len(checks), "kpis": kpis, "quality": quality}, indent=2, default=json_default))
    if not success:
        failures = [check["check"] for check in checks if not check["passed"]]
        raise AssertionError(f"Validation failed: {failures}")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=BASE, help="Portfolio root containing data/raw and checks/expected_checkpoints.json")
    run(parser.parse_args().base.resolve())
