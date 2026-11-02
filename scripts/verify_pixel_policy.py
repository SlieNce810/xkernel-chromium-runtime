#!/usr/bin/env python3
"""Enforce the decision framebuffer policy: every PPM must be 1280x800."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HEADER = re.compile(rb"^P6\s+(\d+)\s+(\d+)\s+255\s", re.S)
EXPECTED = (1280, 800)
EXPECTED_BYTES = 16 + EXPECTED[0] * EXPECTED[1] * 3


def inspect(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    match = HEADER.match(data)
    if not match:
        return {"path": str(path), "pass": False, "error": "invalid P6 header"}
    width, height = map(int, match.groups())
    ok = (width, height) == EXPECTED and len(data) == EXPECTED_BYTES
    return {
        "path": str(path),
        "width": width,
        "height": height,
        "bytes": len(data),
        "expected_bytes": EXPECTED_BYTES,
        "pass": ok,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="PPM file or directory to inspect")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()
    paths = sorted(args.path.glob("**/*.ppm")) if args.path.is_dir() else [args.path]
    if not paths:
        print("no PPM files found", file=sys.stderr)
        return 2
    rows = [inspect(path) for path in paths]
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        for row in rows:
            status = "PASS" if row["pass"] else "FAIL"
            print(f"{status} {row['path']} {row.get('width', '?')}x{row.get('height', '?')} bytes={row.get('bytes', '?')}")
    return 0 if all(bool(row["pass"]) for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
