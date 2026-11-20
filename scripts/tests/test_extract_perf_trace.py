#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for safe serial extraction of guest Chromium traces."""

from __future__ import annotations

import base64
import gzip
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t490"))
import extract_perf_trace  # noqa: E402


RUN_ID = "perf-trace-fixture-r1"
TRACE = json.dumps({"traceEvents": [{"name": "BrowserMain:MESSAGE_LOOP", "ts": 10}]},
                   separators=(",", ":")).encode()
COMPRESSED = base64.b64encode(gzip.compress(TRACE)).decode()
CHUNKS = [COMPRESSED[index:index + 32] for index in range(0, len(COMPRESSED), 32)]


def console_text(*, run_id: str = RUN_ID, chunks: list[str] | None = None,
                 raw: bytes = TRACE, end: bool = True, data_run_id: str | None = None,
                 sequenced: bool = False, omit_chunk_index: int | None = None) -> str:
    data_run_id = data_run_id or run_id
    chunks = CHUNKS if chunks is None else chunks
    rows = [f"[mpdiag] MP_PERF_TRACE_EXPORT_BEGIN run_id={run_id} bytes={len(raw)} sha256={hashlib.sha256(raw).hexdigest()}"]
    for index, chunk in enumerate(chunks):
        if index == omit_chunk_index:
            continue
        sequence = f" seq={index}" if sequenced else ""
        rows.append(f"[mpdiag] MP_PERF_TRACE_DATA run_id={data_run_id}{sequence} {chunk}")
    if end:
        chunk_count = f" chunks={len(chunks)}" if sequenced else ""
        rows.append(f"[mpdiag] MP_PERF_TRACE_EXPORT_END run_id={run_id} encoding=gzip+base64{chunk_count}")
    return "\n".join(rows) + "\n"


class ExtractPerfTraceTests(unittest.TestCase):
    def test_extracts_and_verifies_complete_trace(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            log = root / "console.log"
            out = root / "trace.json"
            log.write_text(console_text(), encoding="utf-8")
            summary = extract_perf_trace.extract_trace(log, out, RUN_ID)
            self.assertEqual(TRACE, out.read_bytes())
            self.assertEqual(1, summary["events"])
            with self.assertRaises(FileExistsError):
                extract_perf_trace.extract_trace(log, out, RUN_ID)

    def test_extracts_sequenced_trace_and_checks_chunk_count(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            log = root / "console.log"
            out = root / "trace.json"
            log.write_text(console_text(sequenced=True), encoding="utf-8")
            summary = extract_perf_trace.extract_trace(log, out, RUN_ID)
            self.assertEqual(TRACE, out.read_bytes())
            self.assertEqual(1, summary["events"])

    def test_rejects_missing_end_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(end=False), encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "missing"):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", RUN_ID)

    def test_rejects_run_id_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(), encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "does not match"):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", "wrong-run")

    def test_rejects_mismatched_data_run_id(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(data_run_id="other-run"), encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "data run_id"):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", RUN_ID)

    def test_rejects_corrupted_trace_digest(self) -> None:
        bad = TRACE.replace(b"10", b"11")
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(raw=TRACE, chunks=[base64.b64encode(gzip.compress(bad)).decode()]),
                           encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "byte count mismatch|SHA-256 mismatch"):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", RUN_ID)

    def test_rejects_invalid_gzip_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(chunks=[base64.b64encode(b"not gzip").decode()]), encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "gzip decode failed"):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", RUN_ID)

    def test_reports_non_utf8_trace_after_integrity_checks(self) -> None:
        raw = b'{"traceEvents":[\xe0]}'
        chunks = [base64.b64encode(gzip.compress(raw)).decode()]
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(raw=raw, chunks=chunks), encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "not UTF-8 JSON.*prefix_hex="):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", RUN_ID)

    def test_rejects_missing_chunk_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "console.log"
            log.write_text(console_text(sequenced=True, omit_chunk_index=1), encoding="utf-8")
            with self.assertRaisesRegex(extract_perf_trace.TraceExportError, "sequence mismatch"):
                extract_perf_trace.extract_trace(log, Path(temp) / "trace.json", RUN_ID)


if __name__ == "__main__":
    unittest.main()
