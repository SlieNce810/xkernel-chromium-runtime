#!/usr/bin/env python3
"""Recover a gzip+base64 Chromium trace streamed through QEMU's serial log.

The guest may write the trace under /root on an ephemeral mount. In that case
autorun emits MP_PERF_TRACE_BEGIN/DATA/END markers to the serial console so the
host can recover the exact JSON without mounting or changing the guest image.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import gzip
import hashlib
import json
import re
import sys
import zlib
from pathlib import Path
from typing import Any


ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
BEGIN = re.compile(
    r"MP_PERF_TRACE_EXPORT_BEGIN\s+run_id=(\S+)\s+bytes=(\d+)\s+(?:chunks=(\d+)\s+)?sha256=([0-9a-f]{64})"
)
DATA = re.compile(r"MP_PERF_TRACE_DATA\s+run_id=(\S+)\s+(?:seq=(\d+)\s+)?([A-Za-z0-9+/=]+)")
END = re.compile(
    r"MP_PERF_TRACE_EXPORT_END\s+run_id=(\S+)\s+encoding=gzip\+base64(?:\s+chunks=(\d+))?"
)


class TraceExportError(ValueError):
    """The serial log does not contain a complete, verifiable trace export."""


def extract_trace(console_log: Path, output: Path, expected_run_id: str | None = None) -> dict[str, Any]:
    text = console_log.read_text(encoding="utf-8", errors="replace")
    header: tuple[str, int, str] | None = None
    chunks: list[str] = []
    ended = False
    header_chunk_count: int | None = None
    end_chunk_count: int | None = None
    sequenced: bool | None = None

    for raw_line in text.splitlines():
        line = ANSI_ESCAPE.sub("", raw_line)
        match = BEGIN.search(line)
        if match:
            if header is not None:
                raise TraceExportError("multiple trace export begin markers")
            header_chunk_count = int(match.group(3)) if match.group(3) is not None else None
            header = (match.group(1), int(match.group(2)), match.group(4).lower())
            continue

        match = DATA.search(line)
        if match:
            if header is None or ended:
                raise TraceExportError("trace data appeared outside the export block")
            if match.group(1) != header[0]:
                raise TraceExportError("trace data run_id does not match begin marker")
            sequence = match.group(2)
            if sequence is not None:
                if sequenced is False:
                    raise TraceExportError("trace data mixes sequenced and unsequenced chunks")
                sequenced = True
                if int(sequence) != len(chunks):
                    raise TraceExportError(
                        f"trace data sequence mismatch: expected {len(chunks)}, got {sequence}"
                    )
            elif sequenced is True:
                raise TraceExportError("trace data mixes sequenced and unsequenced chunks")
            else:
                sequenced = False
            chunks.append(match.group(3))
            continue

        match = END.search(line)
        if match:
            if header is None or ended:
                raise TraceExportError("trace export end marker has no unique begin")
            if match.group(1) != header[0]:
                raise TraceExportError("trace end run_id does not match begin marker")
            end_chunk_count = int(match.group(2)) if match.group(2) is not None else None
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
    if header_chunk_count is not None and header_chunk_count != len(chunks):
        raise TraceExportError(
            f"trace chunk count mismatch: begin declares {header_chunk_count}, got {len(chunks)}"
        )
    if end_chunk_count is not None and end_chunk_count != len(chunks):
        raise TraceExportError(
            f"trace chunk count mismatch: end declares {end_chunk_count}, got {len(chunks)}"
        )
    if sequenced is True and end_chunk_count is None:
        raise TraceExportError("sequenced trace export is missing its end chunk count")

    try:
        compressed = base64.b64decode("".join(chunks), validate=True)
    except (ValueError, binascii.Error) as exc:
        raise TraceExportError(f"trace base64 decode failed after {len(chunks)} chunks: {exc}") from exc
    try:
        payload = gzip.decompress(compressed)
    except (OSError, EOFError, zlib.error) as exc:
        raise TraceExportError(f"trace gzip decode failed after {len(chunks)} chunks: {exc}") from exc
    if len(payload) != expected_bytes:
        raise TraceExportError(f"trace byte count mismatch: expected {expected_bytes}, got {len(payload)}")
    actual_sha = hashlib.sha256(payload).hexdigest()
    if actual_sha != expected_sha:
        raise TraceExportError(f"trace SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")
    try:
        document = json.loads(payload)
    except UnicodeDecodeError as exc:
        prefix_hex = payload[:32].hex()
        raise TraceExportError(
            f"trace payload is not UTF-8 JSON: invalid byte at offset {exc.start}; prefix_hex={prefix_hex}"
        ) from exc
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
