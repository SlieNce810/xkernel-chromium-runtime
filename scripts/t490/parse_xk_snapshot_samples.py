#!/usr/bin/env python3
"""Parse serialised ``xk_memory_snapshot`` sampler blocks.

The guest sampler writes a begin/data/end marker around each procfs read.  The
serial console can lose or interleave a block while other diagnostics write to
the same device, so this parser reports both observed blocks and complete
snapshot rows.  It never promotes a partial or row-count-mismatched block to a
valid sample.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
from pathlib import Path
from typing import Any, Iterable


BEGIN_RE = re.compile(
    r"^XK_MEMORY_SNAPSHOT_SAMPLE_BEGIN id=(\d+) pid=(\d+) begin_ms=(\d+)$"
)
DATA_RE = re.compile(r"^XK_MEMORY_SNAPSHOT_SAMPLE_DATA id=(\d+) end_ms=(\d+)$")
END_RE = re.compile(r"^XK_MEMORY_SNAPSHOT_SAMPLE_END id=(\d+)$")


def key_values(line: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for token in line.split():
        if "=" in token:
            key, value = token.split("=", 1)
            values[key] = value
    return values


def read_blocks(console: Path) -> dict[int, dict[str, Any]]:
    blocks: dict[int, dict[str, Any]] = {}
    active: int | None = None
    for raw_line in console.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.rstrip("\r")
        match = BEGIN_RE.match(line)
        if match:
            active = int(match.group(1))
            blocks[active] = {
                "sample_id": active,
                "pid": int(match.group(2)),
                "begin_ms": int(match.group(3)),
                "lines": [],
            }
            continue
        if active is None:
            continue
        match = DATA_RE.match(line)
        if match and int(match.group(1)) == active:
            blocks[active]["end_ms"] = int(match.group(2))
            blocks[active]["data_seen"] = True
            continue
        match = END_RE.match(line)
        if match and int(match.group(1)) == active:
            blocks[active]["end_seen"] = True
            active = None
            continue
        blocks[active]["lines"].append(line)
    return blocks


def parse_samples(blocks: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    for sample_id in sorted(blocks):
        block = blocks[sample_id]
        lines = block["lines"]
        header = next(
            (line for line in lines if line.startswith("snapshot version=1 ")), None
        )
        processes = [
            key_values(line) for line in lines if line.startswith("process pid=")
        ]
        trailer = next(
            (line for line in lines if line.startswith("snapshot-end rows=")), None
        )
        sample = {key: value for key, value in block.items() if key != "lines"}
        sample["read_ms"] = (
            sample["end_ms"] - sample["begin_ms"]
            if "end_ms" in sample
            else None
        )
        sample["processes"] = processes
        sample["raw_header"] = header
        sample["raw_trailer"] = trailer
        sample["complete"] = False
        sample["rows"] = 0
        sample["reason"] = "missing_snapshot_data"
        if header:
            header_values = key_values(header)
            sample["complete"] = header_values.get("complete") == "1"
            for name in ("root_pid", "t_ns", "tree_generation"):
                if name in header_values:
                    sample[name] = header_values[name]
            sample["reason"] = header_values.get(
                "reason", "complete" if sample["complete"] else "incomplete"
            )
        if trailer:
            try:
                sample["rows"] = int(trailer.split("=", 1)[1])
            except ValueError:
                sample["reason"] = "invalid_snapshot_end"
        if sample["complete"] and sample["rows"] != len(processes):
            sample["complete"] = False
            sample["reason"] = "row_count_mismatch"
        samples.append(sample)
    return samples


def percentile(values: Iterable[float], fraction: float) -> float | None:
    ordered = list(values)
    if not ordered:
        return None
    if len(ordered) == 1:
        return ordered[0]
    return statistics.quantiles(ordered, n=100, method="inclusive")[
        round(fraction * 100) - 1
    ]


def summarize(samples: list[dict[str, Any]], run_id: str) -> dict[str, Any]:
    valid = [sample for sample in samples if sample["complete"]]
    read_ms = [sample["read_ms"] for sample in samples if sample["read_ms"] is not None]
    begins = [sample["begin_ms"] for sample in samples]
    intervals = [
        later - earlier
        for earlier, later in zip(begins, begins[1:])
        if later >= earlier
    ]
    reasons = sorted({sample["reason"] for sample in samples})
    return {
        "schema": "xkernel.procfs-snapshot-sampler.v1",
        "run_id": run_id,
        "sample_count": len(samples),
        "complete_count": len(valid),
        "invalid_count": len(samples) - len(valid),
        "invalid_reasons": {
            reason: sum(sample["reason"] == reason for sample in samples)
            for reason in reasons
        },
        "read_duration_ms": {
            "count": len(read_ms),
            "min": min(read_ms) if read_ms else None,
            "median": statistics.median(read_ms) if read_ms else None,
            "p95": percentile(read_ms, 0.95),
            "max": max(read_ms) if read_ms else None,
        },
        "begin_interval_ms": {
            "count": len(intervals),
            "min": min(intervals) if intervals else None,
            "median": statistics.median(intervals) if intervals else None,
            "p95": percentile(intervals, 0.95),
            "max": max(intervals) if intervals else None,
        },
        "row_count": {
            "min": min((sample["rows"] for sample in valid), default=None),
            "max": max((sample["rows"] for sample in valid), default=None),
        },
        "formal_metric_status": (
            "diagnostic-only; not a 1 Hz formal before/after sample"
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--run", required=True)
    args = parser.parse_args()

    samples = parse_samples(read_blocks(args.console))
    summary = summarize(samples, args.run)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "snapshot-sampler-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.out_dir / "snapshot-samples.jsonl").write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )
    index = "\n".join(
        f"id={sample['sample_id']} begin_ms={sample['begin_ms']} "
        f"end_ms={sample.get('end_ms', '')} read_ms={sample.get('read_ms', '')} "
        f"complete={int(sample['complete'])} rows={sample['rows']} "
        f"reason={sample['reason']}"
        for sample in samples
    )
    (args.out_dir / "snapshot-sampler-index.txt").write_text(
        index + ("\n" if index else ""), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
