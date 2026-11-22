#!/usr/bin/env python3
"""Derive auditable startup and first-screendump upper-bound metrics.

This path is intentionally separate from collect_metrics.py.  It accepts a
partial run when lifecycle startup and strict screenshot evidence are valid,
while preserving renderer-create and RSS/PSS/USS as explicit invalid fields.
It never appends rows to the formal before/after CSV.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


def read_events(paths: list[Path]) -> list[dict[str, Any]]:
    """Read the base and probe event streams into one guest-clock order."""

    rows: list[dict[str, Any]] = []
    for path in paths:
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    rows.sort(key=lambda row: (int(row["t_ns"]), row.get("event_id", "")))
    return rows


def first_strict_shot(evidence: Path) -> tuple[float, str]:
    rows: list[tuple[float, str]] = []
    with (evidence / "timestamps.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            if row.get("result", "").lower() not in {"true", "1", "ok"}:
                continue
            try:
                elapsed = float(row["elapsed_sec"])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError("timestamps.csv has an invalid elapsed_sec") from exc
            image_name = Path(row.get("file", "")).name
            assert_name = evidence / f"ppm-assert-{image_name.replace('.ppm', '.json')}"
            if not assert_name.is_file():
                # round_assert uses this compact name in some runs.
                matches = sorted(evidence.glob(f"ppm-assert-*{Path(image_name).stem}*.json"))
                assert_name = matches[0] if matches else assert_name
            if not assert_name.is_file():
                continue
            data = json.loads(assert_name.read_text(encoding="utf-8"))
            if int(data.get("strict_fail_count", 1)) == 0:
                rows.append((elapsed, image_name))
    if not rows:
        raise ValueError("no strict passing screendump was found")
    return min(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--lifecycle-events", type=Path, action="append", required=True)
    parser.add_argument(
        "--lifecycle-probe-events", type=Path, action="append", default=[]
    )
    parser.add_argument("--run", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--memory-validation", type=Path)
    args = parser.parse_args()

    events = read_events(args.lifecycle_events + args.lifecycle_probe_events)
    if not events:
        raise ValueError("no lifecycle events were found")
    if any(row.get("run_id") != args.run for row in events):
        raise ValueError("lifecycle events contain a different run_id")
    launch = next(row for row in events if row.get("event") == "browser_launch_requested")
    ready = next(row for row in events if row.get("event") == "browser_main_loop_ready")
    navigation = next(row for row in events if row.get("event") == "navigation_requested")
    if int(ready["t_ns"]) <= int(launch["t_ns"]):
        raise ValueError("browser_main_loop_ready precedes launch")
    if int(navigation["t_ns"]) < int(ready["t_ns"]):
        raise ValueError("navigation precedes browser readiness")

    elapsed, screenshot = first_strict_shot(args.evidence)
    spacing: list[float] = []
    with (args.evidence / "timestamps.csv").open(newline="", encoding="utf-8") as stream:
        values = [float(row["elapsed_sec"]) for row in csv.DictReader(stream)
                  if row.get("elapsed_sec")]
    spacing = [b - a for a, b in zip(values, values[1:]) if b >= a]
    payload: dict[str, Any] = {
        "schema": "xkernel.partial-perf.v1",
        "run": args.run,
        "valid_partial": True,
        "clock_id": launch.get("clock_id"),
        "startup": {
            "valid": True,
            "value_ms": (int(ready["t_ns"]) - int(launch["t_ns"])) / 1_000_000,
            "source": "guest lifecycle events",
        },
        "page_first_screendump_upper_bound": {
            "valid": True,
            "value_ms": elapsed * 1000.0,
            "screenshot": screenshot,
            "source": "strict QMP screendump timestamp",
            "sampling_interval_ms": min(spacing) * 1000.0 if spacing else None,
        },
        "page_first_frame": {
            "valid": False,
            "reason": "native first_valid_frame event is unavailable; screendump upper bound is reported separately",
        },
        "renderer_create": {
            "valid": False,
            "reason": "renderer_ready event is unavailable in this run",
        },
        "peak_memory": {
            "valid": False,
            "reason": "RSS/PSS/USS sampler validation failed",
        },
    }
    if args.memory_validation and args.memory_validation.is_file():
        validation = json.loads(args.memory_validation.read_text(encoding="utf-8"))
        payload["peak_memory"]["validation"] = {
            "valid": bool(validation.get("valid")),
            "errors": validation.get("errors", []),
            "sample_count": validation.get("memory_sample_ids"),
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
