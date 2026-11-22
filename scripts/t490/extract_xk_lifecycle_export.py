#!/usr/bin/env python3
"""Recover lifecycle probe JSONL streamed through the verified xk export protocol."""

from __future__ import annotations

import argparse
import base64
import binascii
import gzip
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any


BEGIN = re.compile(
    r"XK_LIFECYCLE_EXPORT_BEGIN\s+run_id=(\S+)\s+bytes=(\d+)\s+chunks=(\d+)"
    r"\s+sha256=([0-9a-f]{64})\s+gzip_bytes=(\d+)\s+gzip_sha256=([0-9a-f]{64})"
)
DATA = re.compile(
    r"XK_LIFECYCLE_DATA\s+run_id=(\S+)\s+seq=(\d+)\s+len=(\d+)\s+([A-Za-z0-9+/=]+)"
)
END = re.compile(
    r"XK_LIFECYCLE_EXPORT_END\s+run_id=(\S+)\s+encoding=gzip\+base64\s+chunks=(\d+)"
)


class ExportError(ValueError):
    """Lifecycle export is incomplete or fails integrity validation."""


def decode_block(header: dict[str, Any], chunks: list[str], end_count: int | None) -> bytes:
    if end_count is None or len(chunks) != header["chunks"] or end_count != len(chunks):
        raise ExportError("lifecycle export chunk count mismatch")
    try:
        compressed = base64.b64decode("".join(chunks), validate=True)
        raw = gzip.decompress(compressed)
    except (ValueError, binascii.Error, OSError, EOFError) as exc:
        raise ExportError(f"lifecycle gzip/base64 decode failed: {exc}") from exc
    if len(compressed) != header["gzip_bytes"] or hashlib.sha256(compressed).hexdigest() != header["gzip_sha256"]:
        raise ExportError("lifecycle gzip length/SHA mismatch")
    if len(raw) != header["raw_bytes"] or hashlib.sha256(raw).hexdigest() != header["raw_sha256"]:
        raise ExportError("lifecycle raw length/SHA mismatch")
    return raw


def decode(console: Path, run_id: str) -> bytes:
    header: dict[str, Any] | None = None
    chunks: list[str] = []
    ended = False
    end_count: int | None = None
    completed: list[bytes] = []
    for line_no, line in enumerate(
        console.read_text(encoding="utf-8", errors="replace").splitlines(), 1
    ):
        match = BEGIN.search(line)
        if match:
            if header is not None:
                if ended and header["run_id"] == run_id:
                    completed.append(decode_block(header, chunks, end_count))
                # A console screendump can interrupt an early export before its
                # chunks/end marker. Discard that incomplete block and use the
                # later complete export, which contains more observations.
            header = {
                "run_id": match.group(1),
                "raw_bytes": int(match.group(2)),
                "chunks": int(match.group(3)),
                "raw_sha256": match.group(4),
                "gzip_bytes": int(match.group(5)),
                "gzip_sha256": match.group(6),
            }
            chunks = []
            ended = False
            end_count = None
            continue
        match = DATA.search(line)
        if match:
            if header is None or ended:
                raise ExportError(f"lifecycle data outside export at line {line_no}")
            if match.group(1) != header["run_id"] or int(match.group(2)) != len(chunks):
                raise ExportError(f"lifecycle chunk sequence/run mismatch at line {line_no}")
            if int(match.group(3)) != len(match.group(4)):
                raise ExportError(f"lifecycle chunk length mismatch at line {line_no}")
            chunks.append(match.group(4))
            continue
        match = END.search(line)
        if match:
            if header is None or ended or match.group(1) != header["run_id"]:
                raise ExportError("invalid lifecycle export end marker")
            end_count = int(match.group(2))
            ended = True
    if header is not None and header["run_id"] == run_id and ended:
        completed.append(decode_block(header, chunks, end_count))
    if not completed:
        raise ExportError("no complete lifecycle export for requested run_id")
    # A watcher can export an early partial file and a later, larger file. Use
    # the last complete block, which has the most lifecycle observations.
    return completed[-1]


def read_members(raw: bytes) -> dict[str, bytes]:
    allowed = {"lifecycle-probe-events.jsonl", "lifecycle-events.jsonl"}
    result: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            parts = tuple(part for part in path.parts if part not in (".", ""))
            if path.is_absolute() or ".." in parts or len(parts) != 1 or parts[0] not in allowed:
                raise ExportError(f"unexpected lifecycle tar member: {member.name!r}")
            if not member.isfile() or parts[0] in result:
                raise ExportError(f"invalid lifecycle tar member: {member.name!r}")
            stream = archive.extractfile(member)
            if stream is None:
                raise ExportError(f"cannot read lifecycle tar member: {member.name!r}")
            result[parts[0]] = stream.read()
    if "lifecycle-probe-events.jsonl" not in result:
        raise ExportError("lifecycle probe member is missing")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    members = read_members(decode(args.console, args.run_id))
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, content in members.items():
        (args.out_dir / name).write_bytes(content)
    summary = {"schema": "xkernel.lifecycle-export.v1", "run_id": args.run_id, "members": sorted(members), "integrity": "PASS"}
    (args.out_dir / "xk-lifecycle-export.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
