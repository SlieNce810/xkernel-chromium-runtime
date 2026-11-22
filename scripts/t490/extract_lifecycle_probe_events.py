#!/usr/bin/env python3
"""Extract and validate lifecycle preload JSONL from a T490 console log.

The guest lifecycle preload writes JSONL to a non-persistent guest path and the
autorun streams it as ``MP_LIFECYCLE_PROBE_EVENT`` markers.  This utility keeps
the original console immutable, validates the run/clock/sequence/event identity
and writes a reusable JSONL file plus a compact extraction summary.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


EVENT_SCHEMA = "xkernel.browser.lifecycle.v1"
CLOCK_ID = "LINUX_CLOCK_MONOTONIC"
MARKER = re.compile(
    r"MP_LIFECYCLE_PROBE_EVENT\s+run_id=(\S+)\s+seq=(\d+)\s+(\{.*\})"
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


class LifecycleExtractionError(ValueError):
    """The console does not contain a complete, valid lifecycle stream."""


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool):
        raise LifecycleExtractionError(f"{label} must be an integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise LifecycleExtractionError(f"{label} must be an integer") from exc
    if result <= 0:
        raise LifecycleExtractionError(f"{label} must be positive")
    return result


def extract(console: Path, run_id: str, allow_export_gaps: bool = False) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if not console.is_file():
        raise LifecycleExtractionError(f"console log missing: {console}")
    rows: list[dict[str, Any]] = []
    event_ids: set[str] = set()
    export_sequences: list[int] = []
    previous_t_ns = 0
    for line_number, raw_line in enumerate(
        console.read_text(encoding="utf-8", errors="replace").splitlines(), 1
    ):
        line = ANSI_ESCAPE.sub("", raw_line)
        match = MARKER.search(line)
        if not match:
            continue
        marker_run, marker_seq_text, raw_json = match.groups()
        if marker_run != run_id:
            raise LifecycleExtractionError(
                f"line {line_number}: marker run_id {marker_run!r} does not match {run_id!r}"
            )
        marker_seq = int(marker_seq_text)
        export_sequences.append(marker_seq)
        try:
            event = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise LifecycleExtractionError(f"line {line_number}: invalid event JSON: {exc}") from exc
        if not isinstance(event, dict):
            raise LifecycleExtractionError(f"line {line_number}: lifecycle event is not an object")
        if event.get("schema") != EVENT_SCHEMA:
            raise LifecycleExtractionError(f"line {line_number}: unexpected schema")
        if event.get("run_id") != run_id:
            raise LifecycleExtractionError(f"line {line_number}: event run_id mismatch")
        if event.get("clock_id") != CLOCK_ID:
            raise LifecycleExtractionError(f"line {line_number}: unexpected clock_id")
        seq = _positive_int(event.get("seq"), f"line {line_number} seq")
        t_ns = _positive_int(event.get("t_ns"), f"line {line_number} t_ns")
        if t_ns < previous_t_ns:
            raise LifecycleExtractionError(f"line {line_number}: event time moved backwards")
        previous_t_ns = t_ns
        event_id = event.get("event_id")
        if not isinstance(event_id, str) or not event_id:
            raise LifecycleExtractionError(f"line {line_number}: event_id is missing")
        if event_id in event_ids:
            raise LifecycleExtractionError(f"line {line_number}: duplicate event_id {event_id}")
        event_ids.add(event_id)
        if not isinstance(event.get("event"), str) or not event["event"]:
            raise LifecycleExtractionError(f"line {line_number}: event name is missing")
        event = dict(event)
        event["export_seq"] = marker_seq
        event["console_line"] = line_number
        rows.append(event)

    if not rows:
        raise LifecycleExtractionError("no MP_LIFECYCLE_PROBE_EVENT markers found")
    if export_sequences != list(range(len(export_sequences))):
        if not allow_export_gaps:
            raise LifecycleExtractionError(
                "export sequence is not contiguous: "
                + ",".join(str(value) for value in export_sequences)
            )
    summary = {
        "schema": "xkernel.lifecycle-extraction.v1",
        "run_id": run_id,
        "clock_id": CLOCK_ID,
        "valid": True,
        "event_count": len(rows),
        "first_seq": rows[0]["seq"],
        "last_seq": rows[-1]["seq"],
        "first_t_ns": rows[0]["t_ns"],
        "last_t_ns": rows[-1]["t_ns"],
        "export_sequence_contiguous": export_sequences == list(range(len(export_sequences))),
        "event_types": sorted({str(row["event"]) for row in rows}),
    }
    return rows, summary


def write_outputs(rows: list[dict[str, Any]], summary: dict[str, Any], output: Path, summary_path: Path | None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    if summary_path is not None:
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        with summary_path.open("x", encoding="utf-8") as stream:
            json.dump(summary, stream, ensure_ascii=False, indent=2)
            stream.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--allow-export-gaps", action="store_true")
    args = parser.parse_args()
    try:
        rows, summary = extract(args.console, args.run_id, args.allow_export_gaps)
        write_outputs(rows, summary, args.out, args.summary)
    except (LifecycleExtractionError, OSError, ValueError) as exc:
        print(f"LIFECYCLE_INVALID: {exc}", file=sys.stderr)
        return 4
    print(f"LIFECYCLE_VALID run={args.run_id} events={len(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
