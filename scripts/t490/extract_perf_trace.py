#!/usr/bin/env python3
"""Recover a gzip+base64 Chromium trace streamed through QEMU's serial log.

The guest may write the trace under /root on an ephemeral mount. In that case
autorun emits MP_PERF_TRACE_BEGIN/DATA/END markers to the serial console so the
host can recover the exact JSON without mounting or changing the guest image.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
BEGIN = re.compile(
    r"MP_PERF_TRACE_EXPORT_BEGIN\s+run_id=(\S+)\s+bytes=(\d+)\s+sha256=([0-9a-f]{64})"
)
DATA = re.compile(r"MP_PERF_TRACE_DATA\s+run_id=(\S+)\s+([A-Za-z0-9+/=]+)")
END = re.compile(r"MP_PERF_TRACE_EXPORT_END\s+run_id=(\S+)\s+encoding=gzip\+base64")


class TraceExportError(ValueError):
    """The serial log does not contain a complete, verifiable trace export."""


def extract_trace(console_log: Path, output: Path, expected_run_id: str | None = None) -> dict[str, Any]:
    text = console_log.read_text(encoding="utf-8", errors="replace")
    header: tuple[str, int, str] | None = None
    chunks: list[str] = []
    ended = False

    for raw_line in text.splitlines():
        line = ANSI_ESCAPE.sub("", raw_line)
        match = BEGIN.search(line)
        if match:
            if header is not None:
                raise TraceExportError("multiple trace export begin markers")
            header = (match.group(1), int(match.group(2)), match.group(3).lower())
            continue

        match = DATA.search(line)
        if match:
            if header is None or ended:
                raise TraceExportError("trace data appeared outside the export block")
            if match.group(1) != header[0]:
                raise TraceExportError("trace data run_id does not match begin marker")
            chunks.append(match.group(2))
            continue

        match = END.search(line)
        if match:
            if header is None or ended:
                raise TraceExportError("trace export end marker has no unique begin")
            if match.group(1) != header[0]:
                raise TraceExportError("trace end run_id does not match begin marker")
            ended = True

    if header is None:
        raise TraceExportError("no MP_PERF_TRACE_EXPORT_BEGIN marker found")
    if not ended:
        raise TraceExportError("trace export is missing MP_PERF_TRACE_EXPORT_END")
    run_id, expected_bytes, expected_sha = header
    if expected_run_id and run_id != expected_run_id:
        raise TraceExportError(f"trace run_id {run_id!r} does not match {expected_run_id!r}")
    if not chunks:
        raise TraceExportError("trace export contains no base64 data chunks")

    try:
        compressed = base64.b64decode("".join(chunks), validate=True)
        payload = gzip.decompress(compressed)
    except (ValueError, OSError) as exc:
        raise TraceExportError(f"trace payload decode failed: {exc}") from exc
    if len(payload) != expected_bytes:
        raise TraceExportError(f"trace byte count mismatch: expected {expected_bytes}, got {len(payload)}")
    actual_sha = hashlib.sha256(payload).hexdigest()
    if actual_sha != expected_sha:
        raise TraceExportError(f"trace SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")
    try:
        document = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise TraceExportError(f"trace payload is not valid JSON: {exc}") from exc
    if not isinstance(document, dict) or not isinstance(document.get("traceEvents"), list):
        raise TraceExportError("trace JSON has no traceEvents array")

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("xb") as stream:
        stream.write(payload)
    return {
        "run_id": run_id,
        "bytes": len(payload),
        "sha256": actual_sha,
        "events": len(document["traceEvents"]),
        "output": str(output),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console_log", type=Path, help="QEMU timestamped console.log")
    parser.add_argument("--out", type=Path, required=True, help="new output JSON path; never overwrites")
    parser.add_argument("--run-id", help="reject trace data from any other diagnostic run")
    args = parser.parse_args()
    try:
        summary = extract_trace(args.console_log, args.out, args.run_id)
    except (OSError, TraceExportError) as exc:
        print(f"PERF_TRACE_EXTRACT_FAIL: {exc}", file=sys.stderr)
        return 1
    print("PERF_TRACE_EXTRACTED " + json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
