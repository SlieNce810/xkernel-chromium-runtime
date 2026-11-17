#!/usr/bin/env python3
"""Compare independent before/after Chromium runs under frozen conditions.

The input CSVs are produced by ``scripts/collect_metrics.py``. This tool
requires complete startup, frame, renderer, and RSS/PSS/USS samples, clean
revision manifests, at least five unique cold starts per side, and an
alternating execution order. It writes a
new JSON report and never edits the raw CSVs or manifests.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


SCHEMA = "xkernel.perf-context.v1"
METRICS = {
    "browser_startup_ms": "ms",
    "page_first_frame_ms": "ms",
    "page_first_screendump_upper_bound_ms": "ms",
    "renderer_create_ms": "ms",
    "peak_chromium_rss_kb": "kB",
    "peak_chromium_pss_kb": "kB",
    "peak_chromium_uss_kb": "kB",
}
MATCH_FIELDS = (
    "host",
    "host_cpu",
    "host_memory_gib",
    "host_os",
    "qemu_version",
    "guest_arch",
    "guest_memory_gib",
    "qemu_accel",
    "chromium_version",
    "chromium_sha256",
    "rootfs_sha256",
    "overlay_sha256",
    "page_sha256",
    "browser_args",
    "profile",
    "sampling_interval_ms",
    "metrics_schema",
)


class ComparisonError(ValueError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ComparisonError(f"cannot read JSON manifest {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ComparisonError(f"manifest must be a JSON object: {path}")
    return value


def validate_manifest(path: Path, expected_variant: str) -> dict[str, Any]:
    manifest = read_json(path)
    if manifest.get("schema") != SCHEMA:
        raise ComparisonError(f"{path}: schema must be {SCHEMA}")
    if manifest.get("variant") != expected_variant:
        raise ComparisonError(f"{path}: variant must be {expected_variant}")
    conditions = manifest.get("conditions")
    implementation = manifest.get("implementation")
    if not isinstance(conditions, dict) or not isinstance(implementation, dict):
        raise ComparisonError(f"{path}: conditions and implementation objects are required")
    missing = [field for field in MATCH_FIELDS if field not in conditions or conditions[field] in (None, "")]
    if missing:
        raise ComparisonError(f"{path}: comparison conditions missing {', '.join(missing)}")
    if conditions["guest_arch"] != "aarch64":
        raise ComparisonError(f"{path}: guest_arch must be aarch64")
    try:
        guest_memory = float(conditions["guest_memory_gib"])
    except (TypeError, ValueError) as exc:
        raise ComparisonError(f"{path}: guest_memory_gib must be numeric") from exc
    if guest_memory != 2.0:
        raise ComparisonError(f"{path}: formal comparison requires the platform default 2 GiB guest")
    if str(conditions["qemu_accel"]).lower() not in {"tcg", "pure-tcg", "tcg-only"}:
        raise ComparisonError(f"{path}: qemu_accel must identify pure TCG")
    for field in ("commit", "git_tag", "kernel_tree_sha256", "kernel_binary_sha256", "kernel_config_sha256"):
        if not implementation.get(field):
            raise ComparisonError(f"{path}: implementation.{field} is required")
    if implementation.get("dirty") is not False:
        raise ComparisonError(f"{path}: implementation must be a clean committed tree")
    if expected_variant == "after" and not implementation.get("parent_commit"):
        raise ComparisonError("after manifest must identify the optimization parent commit")
    return manifest


def validate_conditions(before: dict[str, Any], after: dict[str, Any], comparison_kind: str,
                        baseline_tag: str) -> None:
    left = before["conditions"]
    right = after["conditions"]
    differences = [field for field in MATCH_FIELDS if left[field] != right[field]]
    if differences:
        details = ", ".join(f"{field}: {left[field]!r} != {right[field]!r}" for field in differences)
        raise ComparisonError(f"before/after conditions differ: {details}")
    if comparison_kind == "baseline" and before["implementation"]["git_tag"] != baseline_tag:
        raise ComparisonError(f"baseline comparison must use tag {baseline_tag!r}")
    if comparison_kind == "parent" and after["implementation"]["parent_commit"] != before["implementation"]["commit"]:
        raise ComparisonError("after optimization parent_commit must equal the measured before commit")


def read_samples(path: Path, variant: str) -> dict[str, dict[str, Any]]:
    samples: dict[str, dict[str, Any]] = {}
    seen_pairs: set[tuple[str, str]] = set()
    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        required = {"metric", "run", "value", "unit", "evidence"}
        if required - set(reader.fieldnames or []):
            raise ComparisonError(f"{path}: CSV must contain metric,run,value,unit,evidence")
        for line_number, row in enumerate(reader, 2):
            metric = (row.get("metric") or "").strip()
            if metric not in METRICS:
                continue
            run_id = (row.get("run") or "").strip()
            if not run_id:
                raise ComparisonError(f"{path}:{line_number}: run id is empty")
            if row.get("unit") != METRICS[metric]:
                raise ComparisonError(f"{path}:{line_number}: {metric} must use {METRICS[metric]}")
            if not (row.get("evidence") or "").strip():
                raise ComparisonError(f"{path}:{line_number}: evidence reference is empty")
            try:
                value = float(row.get("value", ""))
            except (TypeError, ValueError) as exc:
                raise ComparisonError(f"{path}:{line_number}: {metric} value is not numeric") from exc
            if not math.isfinite(value) or value <= 0:
                raise ComparisonError(f"{path}:{line_number}: {metric} must be finite and positive")
            pair = (metric, run_id)
            if pair in seen_pairs:
                raise ComparisonError(f"{path}: duplicate metric/run row: {metric}/{run_id}")
            seen_pairs.add(pair)
            samples.setdefault(run_id, {})[metric] = {
                "value": value,
                "unit": METRICS[metric],
                "evidence": row["evidence"],
            }
    if not samples:
        raise ComparisonError(f"{path}: no usable metric samples")
    for run_id, values in samples.items():
        missing = set(METRICS) - set(values)
        if missing:
            raise ComparisonError(f"{path}: run {run_id} is incomplete: {', '.join(sorted(missing))}")
    return samples


def read_order(path: Path, before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]], minimum: int) -> list[tuple[str, str]]:
    rows: list[tuple[int, str, str]] = []
    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        if {"order", "variant", "run"} - set(reader.fieldnames or []):
            raise ComparisonError(f"{path}: execution order CSV needs order,variant,run columns")
        for line_number, row in enumerate(reader, 2):
            try:
                order = int(row.get("order", ""))
            except (TypeError, ValueError) as exc:
                raise ComparisonError(f"{path}:{line_number}: order must be an integer") from exc
            variant = (row.get("variant") or "").strip()
            run_id = (row.get("run") or "").strip()
            if variant not in {"before", "after"} or not run_id:
                raise ComparisonError(f"{path}:{line_number}: invalid variant or run")
            rows.append((order, variant, run_id))
    rows.sort()
    if [row[0] for row in rows] != list(range(1, len(rows) + 1)):
        raise ComparisonError("execution order values must be unique and contiguous from 1")
    before_order = [run for _, variant, run in rows if variant == "before"]
    after_order = [run for _, variant, run in rows if variant == "after"]
    if set(before_order) != set(before) or set(after_order) != set(after):
        raise ComparisonError("execution order must contain every before and after run exactly once")
    if len(before_order) < minimum or len(after_order) < minimum:
        raise ComparisonError(f"need at least {minimum} independent runs on both sides")
    if len(rows) % 2 or any(rows[index][1] == rows[index + 1][1] for index in range(len(rows) - 1)):
        raise ComparisonError("before/after runs must be executed in alternating pairs")
    pairs: list[tuple[str, str]] = []
    for index in range(0, len(rows), 2):
        first, second = rows[index], rows[index + 1]
        pair = {first[1]: first[2], second[1]: second[2]}
        if set(pair) != {"before", "after"}:
            raise ComparisonError("each adjacent execution pair must contain one before and one after run")
        pairs.append((pair["before"], pair["after"]))
    if len(set(run for _, _, run in rows)) != len(rows):
        raise ComparisonError("a run identifier appears more than once in the execution order")
    return pairs


def summarize(values: list[float], run_ids: list[str]) -> dict[str, Any]:
    return {
        "n": len(values),
        "run_ids": run_ids,
        "raw": values,
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "range": max(values) - min(values),
    }


def compare(before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]],
            pairs: list[tuple[str, str]]) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for metric in METRICS:
        before_ids = sorted(before)
        after_ids = sorted(after)
        before_values = [before[run][metric]["value"] for run in before_ids]
        after_values = [after[run][metric]["value"] for run in after_ids]
        before_stats = summarize(before_values, before_ids)
        after_stats = summarize(after_values, after_ids)
        pair_values = [
            {"before_run": before_run, "after_run": after_run,
             "before": before[before_run][metric]["value"],
             "after": after[after_run][metric]["value"],
             "improvement_percent": (before[before_run][metric]["value"] - after[after_run][metric]["value"])
             / before[before_run][metric]["value"] * 100.0}
            for before_run, after_run in pairs
        ]
        improved_pairs = sum(row["after"] < row["before"] for row in pair_values)
        base_median = before_stats["median"]
        current_median = after_stats["median"]
        metrics[metric] = {
            "unit": METRICS[metric],
            "before": before_stats,
            "after": after_stats,
            "median_improvement_percent": (base_median - current_median) / base_median * 100.0,
            "paired_improved_runs": improved_pairs,
            "paired_run_count": len(pair_values),
            "direction_consistent": improved_pairs == len(pair_values),
            "paired_results": pair_values,
        }
    return metrics


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--before-manifest", type=Path, required=True)
    parser.add_argument("--after-manifest", type=Path, required=True)
    parser.add_argument("--order", type=Path, required=True, help="CSV with order,variant,run rows")
    parser.add_argument("--out", type=Path, required=True, help="new JSON output; existing file is not overwritten")
    parser.add_argument("--minimum", type=int, default=5)
    parser.add_argument("--baseline-tag", default="v0.1-first-runnable")
    parser.add_argument("--comparison-kind", choices=("baseline", "parent"), default="parent",
                        help="compare against the first runnable tag or against the optimization parent commit")
    args = parser.parse_args()
    if args.minimum < 5:
        parser.error("minimum must be at least the competition's five repeats")
    try:
        before_manifest = validate_manifest(args.before_manifest, "before")
        after_manifest = validate_manifest(args.after_manifest, "after")
        validate_conditions(before_manifest, after_manifest, args.comparison_kind, args.baseline_tag)
        before = read_samples(args.before, "before")
        after = read_samples(args.after, "after")
        if set(before) & set(after):
            raise ComparisonError("before and after run identifiers must be disjoint")
        if len(before) < args.minimum or len(after) < args.minimum:
            raise ComparisonError(f"need at least {args.minimum} complete independent runs on both sides")
        pairs = read_order(args.order, before, after, args.minimum)
        metrics = compare(before, after, pairs)
        payload = {
            "schema": "xkernel.perf-comparison.v1",
            "valid": True,
            "conditions": before_manifest["conditions"],
            "comparison_kind": args.comparison_kind,
            "required_baseline_tag": args.baseline_tag if args.comparison_kind == "baseline" else None,
            "baseline": before_manifest["implementation"],
            "optimization": after_manifest["implementation"],
            "minimum_runs_per_side": args.minimum,
            "paired_execution_order": str(args.order.resolve()),
            "metrics": metrics,
            "all_metric_directions_consistent": all(row["direction_consistent"] for row in metrics.values()),
            "evidence": {
                "before_csv": str(args.before.resolve()),
                "after_csv": str(args.after.resolve()),
                "before_manifest": str(args.before_manifest.resolve()),
                "after_manifest": str(args.after_manifest.resolve()),
            },
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("x", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        print(f"PERF_COMPARISON_VALID before={len(before)} after={len(after)} metrics={len(metrics)}")
        return 0
    except (ComparisonError, OSError, ValueError) as exc:
        print(f"PERF_COMPARISON_INVALID: {exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
