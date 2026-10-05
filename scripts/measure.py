#!/usr/bin/env python3
"""Aggregate immutable measurement runs using the competition's median rule."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path


def read_values(path: Path) -> dict[str, list[float]]:
    values: dict[str, list[float]] = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            metric = (row.get("metric") or "").strip()
            raw_value = (row.get("value") or "").strip()
            if not metric or not raw_value:
                continue
            values.setdefault(metric, []).append(float(raw_value))
    return values


def summarize(values: dict[str, list[float]], minimum: int) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for metric, samples in sorted(values.items()):
        if len(samples) < minimum:
            raise ValueError(
                f"{metric}: {len(samples)} samples, need at least {minimum}"
            )
        result[metric] = {
            "samples": len(samples),
            "raw": samples,
            "median": statistics.median(samples),
            "min": min(samples),
            "max": max(samples),
            "range": max(samples) - min(samples),
        }
    if not result:
        raise ValueError("no numeric metric rows found")
    return result


def add_baseline_comparison(
    summary: dict[str, dict[str, object]],
    baseline: dict[str, dict[str, object]],
) -> None:
    """Annotate lower-is-better improvement against a frozen summary.

    The competition metrics are latency, memory, and CPU cost, so a positive
    percentage means the current median is lower than the baseline median.
    Missing metrics remain present in the current summary and are marked as
    unavailable instead of being silently dropped.
    """
    for metric, current in summary.items():
        base = baseline.get(metric)
        if not base:
            current["baseline_median"] = None
            current["improvement_percent"] = None
            continue
        base_median = float(base["median"])
        current_median = float(current["median"])
        current["baseline_median"] = base_median
        if base_median == 0:
            current["improvement_percent"] = None
        else:
            current["improvement_percent"] = (base_median - current_median) / base_median * 100.0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Summarize metric samples without modifying raw input data."
    )
    parser.add_argument("input", type=Path, help="CSV with metric,value columns")
    parser.add_argument("output", type=Path, help="new JSON summary path")
    parser.add_argument("--minimum", type=int, default=5)
    parser.add_argument(
        "--baseline",
        type=Path,
        help="existing JSON summary; annotate lower-is-better improvement percentages",
    )
    args = parser.parse_args()
    if args.minimum < 1:
        parser.error("--minimum must be positive")
    summary = summarize(read_values(args.input), args.minimum)
    if args.baseline is not None:
        if not args.baseline.exists():
            parser.error(f"baseline summary does not exist: {args.baseline}")
        with args.baseline.open(encoding="utf-8") as stream:
            baseline = json.load(stream)
        add_baseline_comparison(summary, baseline)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
