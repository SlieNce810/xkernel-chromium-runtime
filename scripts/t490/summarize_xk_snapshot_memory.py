#!/usr/bin/env python3
"""Summarize RSS/PSS/USS from verified xk snapshot JSONL samples."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any


METRICS = ("rss_pages", "pss_pages", "uss_pages", "shared_pages")


def stats(values: list[int]) -> dict[str, Any]:
    return {
        "count": len(values),
        "min_pages": min(values),
        "median_pages": statistics.median(values),
        "max_pages": max(values),
        "min_mib": min(values) * 4096 / (1024 * 1024),
        "median_mib": statistics.median(values) * 4096 / (1024 * 1024),
        "max_mib": max(values) * 4096 / (1024 * 1024),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path)
    parser.add_argument("--run", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    samples: list[dict[str, Any]] = []
    for line in args.samples.read_text(encoding="utf-8").splitlines():
        if line.strip():
            samples.append(json.loads(line))
    if not samples:
        raise ValueError("snapshot JSONL is empty")

    valid = [sample for sample in samples if sample.get("complete")]
    if not valid:
        raise ValueError("snapshot JSONL has no complete samples")
    aggregates: list[dict[str, int]] = []
    root_ids: set[tuple[str, str]] = set()
    generations: set[str] = set()
    for sample in valid:
        root_ids.add((str(sample.get("root_pid", "")), str(sample.get("root_start", ""))))
        generations.add(str(sample.get("tree_generation", "")))
        rows = sample.get("processes") or []
        if not rows:
            raise ValueError(f"sample {sample.get('sample_id')} has no process rows")
        aggregate: dict[str, int] = {}
        for metric in METRICS:
            values: list[int] = []
            for row in rows:
                value = row.get(metric)
                if not isinstance(value, str) or not value.isdigit():
                    raise ValueError(f"sample {sample.get('sample_id')} has invalid {metric}")
                values.append(int(value))
            aggregate[metric] = sum(values)
        aggregates.append(aggregate)

    payload: dict[str, Any] = {
        "schema": "xkernel.partial-memory-summary.v1",
        "run": args.run,
        "valid_partial": True,
        "formal_valid": False,
        "formal_invalid_reason": (
            "window is a delayed diagnostic snapshot series, not launch-to-load-plus-60s"
        ),
        "sample_count": len(samples),
        "complete_sample_count": len(valid),
        "process_rows": {
            "min": min(int(sample["rows"]) for sample in valid),
            "max": max(int(sample["rows"]) for sample in valid),
        },
        "root_identity_count": len(root_ids),
        "tree_generation_count": len(generations),
        "metrics": {metric: stats([row[metric] for row in aggregates]) for metric in METRICS},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
