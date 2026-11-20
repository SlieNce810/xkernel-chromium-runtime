#!/usr/bin/env python3
"""Recover a verified guest RSS/PSS/USS sample bundle from QEMU serial output."""

from __future__ import annotations

import argparse
import base64
import binascii
import csv
import gzip
import hashlib
import io
import json
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any


RUN_SCHEMA = "xkernel.browser.lifecycle.v1"
REQUIRED_FILES = {
    "lifecycle-events.jsonl",
    "memory-samples.csv",
    "memory-sampling-errors.log",
    "proc-tree-sampler.status",
}
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
BEGIN = re.compile(
    r"MP_PERF_MEMORY_EXPORT_BEGIN\s+run_id=(\S+)\s+bytes=(\d+)\s+chunks=(\d+)"
    r"\s+sha256=([0-9a-f]{64})\s+gzip_bytes=(\d+)\s+gzip_sha256=([0-9a-f]{64})"
)
DATA = re.compile(r"MP_PERF_MEMORY_DATA\s+run_id=(\S+)\s+seq=(\d+)\s+len=(\d+)\s+([A-Za-z0-9+/=]+)")
END = re.compile(r"MP_PERF_MEMORY_EXPORT_END\s+run_id=(\S+)\s+encoding=gzip\+base64\s+chunks=(\d+)")


class MemoryExportError(ValueError):
    """The serial log does not contain a complete, verified memory export."""


def decode_payload(console_log: Path, expected_run_id: str | None = None) -> tuple[str, bytes, bytes, int]:
    text = console_log.read_text(encoding="utf-8", errors="replace")
    header: dict[str, Any] | None = None
    chunks: list[str] = []
    ended = False
    end_chunks: int | None = None
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = ANSI_ESCAPE.sub("", raw_line)
        begin = BEGIN.search(line)
        if begin:
            if header is not None:
                raise MemoryExportError("multiple memory export begin markers")
            header = {
                "run_id": begin.group(1),
                "raw_bytes": int(begin.group(2)),
                "chunks": int(begin.group(3)),
                "raw_sha256": begin.group(4).lower(),
                "gzip_bytes": int(begin.group(5)),
                "gzip_sha256": begin.group(6).lower(),
            }
            continue
        data = DATA.search(line)
        if data:
            if header is None or ended:
                raise MemoryExportError(f"memory data appeared outside export block at line {line_number}")
            if data.group(1) != header["run_id"]:
                raise MemoryExportError(f"memory data run_id mismatch at line {line_number}")
            sequence = int(data.group(2))
            if sequence != len(chunks):
                raise MemoryExportError(f"memory chunk sequence mismatch: expected {len(chunks)}, got {sequence}")
            encoded = data.group(4)
            if int(data.group(3)) != len(encoded):
                raise MemoryExportError(f"memory chunk length mismatch at line {line_number}")
            chunks.append(encoded)
            continue
        end = END.search(line)
        if end:
            if header is None or ended:
                raise MemoryExportError("memory export end marker has no unique begin")
            if end.group(1) != header["run_id"]:
                raise MemoryExportError("memory export end run_id mismatch")
            end_chunks = int(end.group(2))
            ended = True

    if header is None:
        raise MemoryExportError("no MP_PERF_MEMORY_EXPORT_BEGIN marker found")
    if expected_run_id and header["run_id"] != expected_run_id:
        raise MemoryExportError(f"run_id {header['run_id']!r} does not match {expected_run_id!r}")
    if not ended:
        raise MemoryExportError("memory export is missing MP_PERF_MEMORY_EXPORT_END")
    if not chunks:
        raise MemoryExportError("memory export contains no data chunks")
    if len(chunks) != header["chunks"] or end_chunks != len(chunks):
        raise MemoryExportError(
            f"memory chunk count mismatch: begin={header['chunks']} end={end_chunks} received={len(chunks)}"
        )
    try:
        compressed = base64.b64decode("".join(chunks), validate=True)
    except (ValueError, binascii.Error) as exc:
        raise MemoryExportError(f"memory base64 decode failed: {exc}") from exc
    if len(compressed) != header["gzip_bytes"]:
        raise MemoryExportError(f"gzip length mismatch: expected={header['gzip_bytes']} got={len(compressed)}")
    compressed_sha = hashlib.sha256(compressed).hexdigest()
    if compressed_sha != header["gzip_sha256"]:
        raise MemoryExportError("gzip SHA-256 mismatch")
    try:
        raw_tar = gzip.decompress(compressed)
    except (OSError, EOFError) as exc:
        raise MemoryExportError(f"gzip decompression failed: {exc}") from exc
    if len(raw_tar) != header["raw_bytes"]:
        raise MemoryExportError(f"tar length mismatch: expected={header['raw_bytes']} got={len(raw_tar)}")
    raw_sha = hashlib.sha256(raw_tar).hexdigest()
    if raw_sha != header["raw_sha256"]:
        raise MemoryExportError("tar SHA-256 mismatch")
    return header["run_id"], compressed, raw_tar, len(chunks)


def read_tar_members(raw_tar: bytes) -> dict[str, bytes]:
    members: dict[str, bytes] = {}
    try:
        archive = tarfile.open(fileobj=io.BytesIO(raw_tar), mode="r:")
    except tarfile.TarError as exc:
        raise MemoryExportError(f"invalid tar archive: {exc}") from exc
    with archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            parts = tuple(part for part in path.parts if part not in (".", ""))
            if path.is_absolute() or ".." in parts or len(parts) != 1:
                raise MemoryExportError(f"unsafe tar member path: {member.name!r}")
            name = parts[0]
            if name not in REQUIRED_FILES:
                raise MemoryExportError(f"unexpected tar member: {member.name!r}")
            if not member.isfile() or name in members:
                raise MemoryExportError(f"invalid or duplicate tar member: {member.name!r}")
            stream = archive.extractfile(member)
            if stream is None:
                raise MemoryExportError(f"cannot read tar member: {member.name!r}")
            members[name] = stream.read()
    missing = REQUIRED_FILES - set(members)
    if missing:
        raise MemoryExportError("required tar members missing: " + ", ".join(sorted(missing)))
    return members


def validate_bundle(run_id: str, members: dict[str, bytes]) -> dict[str, Any]:
    events: list[dict[str, Any]] = []
    last_t_ns = -1
    last_seq = -1
    for line_number, raw in enumerate(members["lifecycle-events.jsonl"].decode("utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise MemoryExportError(f"invalid lifecycle JSON at line {line_number}: {exc}") from exc
        if event.get("schema") != RUN_SCHEMA or event.get("run_id") != run_id:
            raise MemoryExportError(f"lifecycle schema/run mismatch at line {line_number}")
        if event.get("clock_id") != "LINUX_CLOCK_MONOTONIC":
            raise MemoryExportError(f"lifecycle clock mismatch at line {line_number}")
        seq = int(event.get("seq", -1))
        t_ns = int(event.get("t_ns", -1))
        if seq <= last_seq or t_ns < last_t_ns:
            raise MemoryExportError(f"lifecycle sequence/time order invalid at line {line_number}")
        last_seq, last_t_ns = seq, t_ns
        events.append(event)
    if not events:
        raise MemoryExportError("lifecycle event file is empty")

    rows: list[dict[str, str]] = []
    reader = csv.DictReader(io.StringIO(members["memory-samples.csv"].decode("utf-8")))
    required_columns = {
        "run_id", "clock_id", "sample_id", "t_ns", "pid", "ppid", "process_instance",
        "rss_kb", "pss_kb", "uss_kb",
    }
    if required_columns - set(reader.fieldnames or []):
        raise MemoryExportError("memory CSV header is incomplete")
    for index, row in enumerate(reader, 2):
        if row["run_id"] != run_id or row["clock_id"] != "LINUX_CLOCK_MONOTONIC":
            raise MemoryExportError(f"memory CSV run/clock mismatch at row {index}")
        for key in ("t_ns", "pid", "ppid", "rss_kb", "pss_kb", "uss_kb"):
            try:
                value = int(row[key])
            except (ValueError, TypeError) as exc:
                raise MemoryExportError(f"memory CSV field {key} is invalid at row {index}") from exc
            if value < 0:
                raise MemoryExportError(f"memory CSV field {key} is negative at row {index}")
        rows.append(row)
    if not rows:
        raise MemoryExportError("memory CSV contains no samples")

    status = members["proc-tree-sampler.status"].decode("utf-8", errors="replace")
    if f"run_id={run_id}" not in status:
        raise MemoryExportError("sampler status run_id does not match this run")
    validation_errors: list[str] = []
    if "result=PASS" not in status:
        validation_errors.append("sampler status does not report PASS")
    errors = members["memory-sampling-errors.log"].decode("utf-8", errors="replace")
    if errors.strip():
        validation_errors.append(f"sampler recorded {len(errors.splitlines())} memory/tree errors")
    return {
        "schema": "xkernel.proc-tree-memory-export.v1",
        "run_id": run_id,
        "valid": not validation_errors,
        "errors": validation_errors,
        "clock_id": "LINUX_CLOCK_MONOTONIC",
        "lifecycle_events": len(events),
        "memory_rows": len(rows),
        "memory_sample_ids": len({row["sample_id"] for row in rows}),
        "process_instances": len({row["process_instance"] for row in rows}),
        "memory_sampling_errors": len(errors.splitlines()),
    }


def extract(console_log: Path, out_dir: Path, expected_run_id: str | None = None) -> dict[str, Any]:
    if out_dir.exists():
        raise MemoryExportError(f"refusing to reuse output directory: {out_dir}")
    run_id, compressed, raw_tar, chunks = decode_payload(console_log, expected_run_id)
    members = read_tar_members(raw_tar)
    summary = validate_bundle(run_id, members)
    out_dir.mkdir(parents=True)
    (out_dir / "guest-samples.tar.gz").write_bytes(compressed)
    for name, payload in members.items():
        with (out_dir / name).open("xb") as stream:
            stream.write(payload)
    summary.update({
        "chunks": chunks,
        "tar_bytes": len(raw_tar),
        "tar_sha256": hashlib.sha256(raw_tar).hexdigest(),
        "gzip_bytes": len(compressed),
        "gzip_sha256": hashlib.sha256(compressed).hexdigest(),
        "output": str(out_dir.resolve()),
    })
    (out_dir / "extraction.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console_log", type=Path)
    parser.add_argument("--run-id", help="reject memory bundle from another run")
    parser.add_argument("--out-dir", type=Path, required=True, help="new output directory; never overwrites")
    args = parser.parse_args()
    try:
        summary = extract(args.console_log, args.out_dir, args.run_id)
    except (MemoryExportError, OSError, ValueError, tarfile.TarError) as exc:
        print(f"PERF_MEMORY_EXTRACT_FAIL: {exc}", file=sys.stderr)
        return 1
    print("PERF_MEMORY_EXTRACTED " + json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0 if summary["valid"] else 4


if __name__ == "__main__":
    raise SystemExit(main())
