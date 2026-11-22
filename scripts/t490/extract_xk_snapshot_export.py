#!/usr/bin/env python3
"""Recover a verified xk_memory_snapshot bundle streamed over serial."""

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
    r"XK_MEMORY_EXPORT_BEGIN\s+run_id=(\S+)\s+bytes=(\d+)\s+chunks=(\d+)"
    r"\s+sha256=([0-9a-f]{64})\s+gzip_bytes=(\d+)\s+gzip_sha256=([0-9a-f]{64})"
)
DATA = re.compile(
    r"XK_MEMORY_DATA\s+run_id=(\S+)\s+seq=(\d+)\s+len=(\d+)\s+([A-Za-z0-9+/=]+)"
)
END = re.compile(
    r"XK_MEMORY_EXPORT_END\s+run_id=(\S+)\s+encoding=gzip\+base64\s+chunks=(\d+)"
)


class ExportError(ValueError):
    """The serial stream is incomplete or fails an integrity check."""


def decode(console: Path, expected_run_id: str | None) -> tuple[dict[str, Any], bytes]:
    text = console.read_text(encoding="utf-8", errors="replace")
    header: dict[str, Any] | None = None
    chunks: list[str] = []
    ended = False
    end_count: int | None = None
    for line_number, line in enumerate(text.splitlines(), 1):
        begin = BEGIN.search(line)
        if begin:
            if header is not None:
                raise ExportError("multiple export headers")
            header = {
                "run_id": begin.group(1),
                "raw_bytes": int(begin.group(2)),
                "chunks": int(begin.group(3)),
                "raw_sha256": begin.group(4),
                "gzip_bytes": int(begin.group(5)),
                "gzip_sha256": begin.group(6),
            }
            continue
        data = DATA.search(line)
        if data:
            if header is None or ended:
                raise ExportError(f"data outside export at line {line_number}")
            if data.group(1) != header["run_id"]:
                raise ExportError(f"run_id mismatch at line {line_number}")
            sequence = int(data.group(2))
            if sequence != len(chunks):
                raise ExportError(f"chunk sequence mismatch at line {line_number}")
            encoded = data.group(4)
            if int(data.group(3)) != len(encoded):
                raise ExportError(f"chunk length mismatch at line {line_number}")
            chunks.append(encoded)
            continue
        end = END.search(line)
        if end:
            if header is None or ended:
                raise ExportError("invalid export end marker")
            if end.group(1) != header["run_id"]:
                raise ExportError("end run_id mismatch")
            end_count = int(end.group(2))
            ended = True
    if header is None:
        raise ExportError("no export header")
    if expected_run_id and header["run_id"] != expected_run_id:
        raise ExportError("header run_id does not match requested run")
    if not ended or end_count is None:
        raise ExportError("export end marker is missing")
    if len(chunks) != header["chunks"] or end_count != len(chunks):
        raise ExportError("export chunk count mismatch")
    try:
        compressed = base64.b64decode("".join(chunks), validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ExportError(f"base64 decode failed: {exc}") from exc
    if len(compressed) != header["gzip_bytes"]:
        raise ExportError("gzip byte count mismatch")
    if hashlib.sha256(compressed).hexdigest() != header["gzip_sha256"]:
        raise ExportError("gzip SHA-256 mismatch")
    try:
        raw = gzip.decompress(compressed)
    except (OSError, EOFError) as exc:
        raise ExportError(f"gzip decompression failed: {exc}") from exc
    if len(raw) != header["raw_bytes"]:
        raise ExportError("raw byte count mismatch")
    if hashlib.sha256(raw).hexdigest() != header["raw_sha256"]:
        raise ExportError("raw SHA-256 mismatch")
    return header, raw


def read_members(raw: bytes) -> dict[str, bytes]:
    members: dict[str, bytes] = {}
    try:
        archive = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
    except tarfile.TarError as exc:
        raise ExportError(f"invalid tar archive: {exc}") from exc
    with archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            parts = tuple(part for part in path.parts if part not in (".", ""))
            if path.is_absolute() or ".." in parts or len(parts) != 1:
                raise ExportError(f"unsafe tar member {member.name!r}")
            if not member.isfile() or parts[0] in members:
                raise ExportError(f"invalid tar member {member.name!r}")
            stream = archive.extractfile(member)
            if stream is None:
                raise ExportError(f"cannot read tar member {member.name!r}")
            members[parts[0]] = stream.read()
    if set(members) != {"xk-memory-snapshot-samples.log"}:
        raise ExportError(f"unexpected tar members: {sorted(members)}")
    return members


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    header, raw = decode(args.console, args.run_id)
    members = read_members(raw)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    sample_path = args.out_dir / "xk-memory-snapshot-samples.log"
    sample_path.write_bytes(members["xk-memory-snapshot-samples.log"])
    summary = {
        "schema": "xkernel.procfs-snapshot-export.v1",
        "run_id": header["run_id"],
        "raw_bytes": header["raw_bytes"],
        "chunks": header["chunks"],
        "raw_sha256": header["raw_sha256"],
        "gzip_bytes": header["gzip_bytes"],
        "gzip_sha256": header["gzip_sha256"],
        "member": sample_path.name,
        "member_bytes": len(members[sample_path.name]),
        "integrity": "PASS",
    }
    (args.out_dir / "xk-memory-snapshot-export.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
