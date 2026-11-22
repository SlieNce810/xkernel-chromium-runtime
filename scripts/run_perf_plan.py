#!/usr/bin/env python3
"""Collect and compare a frozen before/after performance plan.

The plan references immutable evidence directories containing lifecycle JSONL
and one-second process-tree memory CSVs. Raw rows, per-run validation records,
alternating order, and comparison JSON are written into a new output directory.
Invalid or incomplete inputs stop the batch and never become samples.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any

import collect_metrics
import compare_perf


def resolve(base: Path, value: str) -> Path:
    candidate = Path(value).expanduser()
    return candidate.resolve() if candidate.is_absolute() else (base / candidate).resolve()


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def require_runs(value: Any, variant: str, base: Path) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) < 5:
        raise ValueError(f"plan.{variant}_runs must contain at least five runs")
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate(value, 1):
        row = require_object(item, f"plan.{variant}_runs[{index}]")
        run_id = row.get("run")
        evidence = row.get("evidence")
        if not isinstance(run_id, str) or not run_id.strip() or run_id in seen:
            raise ValueError(f"plan.{variant}_runs has an empty/duplicate run id")
        if not isinstance(evidence, str) or not evidence.strip():
            raise ValueError(f"plan.{variant}_runs[{index}] has no evidence path")
        seen.add(run_id)
        rows.append({"run": run_id, "evidence": resolve(base, evidence)})
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="new output directory; existing directories are not overwritten")
    parser.add_argument("--minimum", type=int, default=5)
    args = parser.parse_args()
    if args.minimum < 5:
        parser.error("minimum must be at least five independent runs per side")

    plan_path = args.plan.expanduser().resolve()
    out = args.out.expanduser().resolve()
    if not plan_path.is_file():
        parser.error(f"plan file missing: {plan_path}")
    if out.exists():
        parser.error(f"refusing to overwrite output directory: {out}")
    out.mkdir(parents=True)
    plan = require_object(json.loads(plan_path.read_text(encoding="utf-8")), "plan")
    if plan.get("schema") != "xkernel.perf-plan.v1":
        raise ValueError("plan schema must be xkernel.perf-plan.v1")
    base = plan_path.parent
    before_runs = require_runs(plan.get("before_runs"), "before", base)
    after_runs = require_runs(plan.get("after_runs"), "after", base)
    all_run_ids = [row["run"] for row in before_runs + after_runs]
    if len(set(all_run_ids)) != len(all_run_ids):
        raise ValueError("before and after run identifiers must be disjoint")
    profile = plan.get("profile", "official-index")
    if not isinstance(profile, str) or not profile:
        raise ValueError("plan.profile must be a non-empty string")

    before_csv = out / "before-raw.csv"
    after_csv = out / "after-raw.csv"
    validation_rows: list[dict[str, Any]] = []
    for variant, rows, csv_path in (
        ("before", before_runs, before_csv),
        ("after", after_runs, after_csv),
    ):
        for row in rows:
            run_id = row["run"]
            evidence = row["evidence"]
            try:
                metrics = collect_metrics.validate_sample(evidence, run_id, profile)
                missing = collect_metrics.REQUIRED_METRICS - {metric["metric"] for metric in metrics}
                if missing:
                    raise collect_metrics.InvalidSample(
                        "required metrics missing: " + ", ".join(sorted(missing))
                    )
                collect_metrics.write_rows(csv_path, metrics)
                validation_rows.append({"variant": variant, "run": run_id, "valid": True,
                                        "evidence": str(evidence), "metric_count": len(metrics)})
            except (collect_metrics.InvalidSample, OSError, ValueError) as exc:
                failure = {"variant": variant, "run": run_id, "valid": False,
                           "evidence": str(evidence), "errors": [str(exc)]}
                validation_rows.append(failure)
                (out / "validation.json").write_text(
                    json.dumps({"schema": "xkernel.perf-plan-validation.v1",
                                "plan": str(plan_path), "runs": validation_rows},
                               ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8",
                )
                print(f"PERF_PLAN_INVALID variant={variant} run={run_id}: {exc}", file=sys.stderr)
                return 4

    before_manifest_path = resolve(base, str(plan.get("before_manifest", "")))
    after_manifest_path = resolve(base, str(plan.get("after_manifest", "")))
    before_manifest = compare_perf.validate_manifest(before_manifest_path, "before")
    after_manifest = compare_perf.validate_manifest(after_manifest_path, "after")
    comparison_kind = plan.get("comparison_kind", "parent")
    baseline_tag = plan.get("baseline_tag", "v0.1-first-runnable")
    if comparison_kind not in {"parent", "baseline"} or not isinstance(baseline_tag, str):
        raise ValueError("invalid comparison_kind or baseline_tag")
    compare_perf.validate_conditions(before_manifest, after_manifest, comparison_kind, baseline_tag)

    order_rows = plan.get("order")
    if not isinstance(order_rows, list):
        raise ValueError("plan.order must be a list of alternating variant/run records")
    order_path = out / "order.csv"
    with order_path.open("x", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["order", "variant", "run"])
        writer.writeheader()
        for row in order_rows:
            item = require_object(row, "plan.order row")
            writer.writerow({"order": item.get("order"), "variant": item.get("variant"), "run": item.get("run")})

    before = compare_perf.read_samples(before_csv, "before")
    after = compare_perf.read_samples(after_csv, "after")
    pairs = compare_perf.read_order(order_path, before, after, args.minimum)
    metrics = compare_perf.compare(before, after, pairs)
    (out / "validation.json").write_text(
        json.dumps({"schema": "xkernel.perf-plan-validation.v1",
                    "plan": str(plan_path), "valid": True, "runs": validation_rows},
                   ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    shutil_plan = json.dumps(plan, ensure_ascii=False, indent=2) + "\n"
    (out / "plan.json").write_text(shutil_plan, encoding="utf-8")
    summary = {
        "schema": "xkernel.perf-comparison.v1",
        "valid": True,
        "comparison_kind": comparison_kind,
        "conditions": before_manifest["conditions"],
        "baseline": before_manifest["implementation"],
        "optimization": after_manifest["implementation"],
        "minimum_runs_per_side": args.minimum,
        "paired_execution_order": str(order_path),
        "metrics": metrics,
        "all_metric_directions_consistent": all(row["direction_consistent"] for row in metrics.values()),
        "validation": str(out / "validation.json"),
    }
    (out / "comparison.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"PERF_PLAN_VALID before={len(before)} after={len(after)} metrics={len(metrics)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, compare_perf.ComparisonError) as exc:
        print(f"PERF_PLAN_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(4)
