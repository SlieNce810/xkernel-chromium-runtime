#!/usr/bin/env python3
"""Extract one immutable measurement row set from a T490 evidence directory.

The collector is deliberately strict: a run without a renderer gate is kept as
diagnostic evidence but cannot contribute renderer or performance samples.
"""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path


MARKER_RE = re.compile(r"\b(MP_[A-Z0-9_]+)=([^\s]+)")


def guest_log(evidence: Path) -> Path | None:
    candidates = sorted(evidence.glob("guest/*mp-diag*.log"))
    if candidates:
        return candidates[-1]
    candidates = sorted(evidence.glob("guest/*chromium*.log"))
    if candidates:
        return candidates[-1]
    console = evidence / "console.log"
    return console if console.exists() else None


def read_markers(path: Path | None) -> dict[str, str]:
    markers: dict[str, str] = {}
    if path is None:
        return markers
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        for key, value in MARKER_RE.findall(line):
            markers[key] = value
    return markers


def first_screenshot(evidence: Path, profile: str) -> tuple[float | None, bool]:
    timestamps = evidence / "timestamps.csv"
    if not timestamps.exists():
        return None, False
    rows: list[tuple[float, Path]] = []
    with timestamps.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            try:
                elapsed = float(row["elapsed_sec"])
            except (KeyError, TypeError, ValueError):
                continue
            if row.get("result", "").lower() not in {"true", "1", "ok"}:
                continue
            path = evidence / "screenshots" / Path(row.get("file", "")).name
            if path.exists():
                rows.append((elapsed, path))
    rows.sort(key=lambda item: item[0])
    if not rows:
        return None, False

    ppm_assert = evidence.parent.parent / "scripts" / "t490" / "ppm_assert.py"
    if not ppm_assert.exists():
        ppm_assert = Path(__file__).with_name("t490") / "ppm_assert.py"
    for elapsed, ppm in rows:
        if not ppm_assert.exists():
            return elapsed, False
        result = subprocess.run(
            [sys.executable, str(ppm_assert), str(ppm), "--profile", profile, "--strict", "--quiet"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return elapsed, True
    return rows[0][0], False


def write_rows(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists()
    with path.open("a", newline="", encoding="utf-8") as stream:
        fields = ["metric", "run", "value", "unit", "evidence"]
        writer = csv.DictWriter(stream, fieldnames=fields)
        if not exists:
            writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--run", required=True)
    parser.add_argument("--csv", dest="csv_path", type=Path, required=True)
    parser.add_argument("--profile", default="official-index")
    args = parser.parse_args()

    evidence = args.evidence.resolve()
    markers = read_markers(guest_log(evidence))
    gate = markers.get("MP_GATE", "0") == "1"
    first_frame, page_pass = first_screenshot(evidence, args.profile)
    rows: list[dict[str, str]] = [
        {"metric": "renderer_gate", "run": args.run, "value": "1" if gate else "0", "unit": "bool", "evidence": str(evidence)},
        {"metric": "page_assertion", "run": args.run, "value": "1" if page_pass else "0", "unit": "bool", "evidence": str(evidence)},
    ]

    if first_frame is not None:
        rows.append({"metric": "first_screendump", "run": args.run, "value": f"{first_frame:.6f}", "unit": "s", "evidence": str(evidence)})
    if "MP_RSS_MAX_KB" in markers:
        rows.append({"metric": "peak_chromium_rss", "run": args.run, "value": markers["MP_RSS_MAX_KB"], "unit": "kB", "evidence": str(evidence)})
    if "MP_BROWSER_START_EPOCH_MS" in markers and "MP_RENDERER_FIRST_EPOCH_MS" in markers:
        start = float(markers["MP_BROWSER_START_EPOCH_MS"])
        first = float(markers["MP_RENDERER_FIRST_EPOCH_MS"])
        rows.append({"metric": "renderer_create", "run": args.run, "value": f"{(first - start) / 1000:.6f}", "unit": "s", "evidence": str(evidence)})
    if "MP_RENDERER_MAX_STREAK" in markers:
        rows.append({"metric": "renderer_max_streak", "run": args.run, "value": markers["MP_RENDERER_MAX_STREAK"], "unit": "samples", "evidence": str(evidence)})

    write_rows(args.csv_path, rows)
    print(f"COLLECTED evidence={evidence} renderer_gate={int(gate)} page_assertion={int(page_pass)} rows={len(rows)}")
    return 0 if gate and page_pass else 4


if __name__ == "__main__":
    raise SystemExit(main())

