#!/usr/bin/env python3
"""Collect single-process initial-round metrics from one immutable evidence bundle."""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path


def find_guest_file(evidence: Path, suffix: str) -> Path | None:
    matches = sorted((evidence / "guest").glob(f"*{suffix}"))
    return matches[-1] if matches else None


def read_text(path: Path | None) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path else ""


def metric_value(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text)
    return match.group(1) if match else None


def first_passing_screenshot(evidence: Path, profile: str) -> float | None:
    timestamps = evidence / "timestamps.csv"
    if not timestamps.exists():
        return None
    assert_script = Path(__file__).parent / "t490" / "ppm_assert.py"
    rows: list[tuple[float, Path]] = []
    with timestamps.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            try:
                elapsed = float(row["elapsed_sec"])
            except (KeyError, TypeError, ValueError):
                continue
            if row.get("result", "").lower() not in {"true", "1", "ok"}:
                continue
            image = evidence / "screenshots" / Path(row.get("file", "")).name
            if image.exists():
                rows.append((elapsed, image))
    for elapsed, image in sorted(rows):
        result = subprocess.run(
            [sys.executable, str(assert_script), str(image), "--profile", profile, "--strict", "--quiet"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return elapsed
    return None


def collect(evidence: Path, run: str, profile: str) -> list[dict[str, str]]:
    log = read_text(find_guest_file(evidence, "_root_single-initial.log"))
    csv_path = find_guest_file(evidence, "_root_single-initial.csv")
    rows: list[dict[str, str]] = []

    gate = metric_value(log, r"SINGLE_GATE=(\d+)") or "0"
    rows.append({"metric": "single_gate", "run": run, "value": gate, "unit": "bool", "evidence": str(evidence)})

    first_nav = metric_value(log, r"FIRST_NAV_ELAPSED=(\d+(?:\.\d+)?)")
    if first_nav is not None:
        rows.append({"metric": "single_first_navigation", "run": run, "value": first_nav, "unit": "s", "evidence": str(evidence)})

    hold = metric_value(log, r"SINGLE_HOLD_REACHED elapsed=(\d+(?:\.\d+)?)")
    if hold is not None:
        rows.append({"metric": "single_hold", "run": run, "value": hold, "unit": "s", "evidence": str(evidence)})

    image_time = first_passing_screenshot(evidence, profile)
    if image_time is not None:
        rows.append({"metric": "first_passing_screendump", "run": run, "value": f"{image_time:.6f}", "unit": "s", "evidence": str(evidence)})
        page_ok = "1"
    else:
        page_ok = "0"
    rows.append({"metric": "page_assertion", "run": run, "value": page_ok, "unit": "bool", "evidence": str(evidence)})

    if csv_path:
        rss_values: list[float] = []
        with csv_path.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                try:
                    value = float(row.get("rss_kb", "0"))
                except (TypeError, ValueError):
                    continue
                if value > 0:
                    rss_values.append(value)
        if rss_values:
            rows.append({"metric": "peak_chromium_rss", "run": run, "value": f"{max(rss_values):.0f}", "unit": "kB", "evidence": str(evidence)})
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--run", required=True)
    parser.add_argument("--csv", dest="csv_path", type=Path, required=True)
    parser.add_argument("--profile", default="official-index")
    args = parser.parse_args()
    rows = collect(args.evidence.resolve(), args.run, args.profile)
    args.csv_path.parent.mkdir(parents=True, exist_ok=True)
    exists = args.csv_path.exists()
    with args.csv_path.open("a", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["metric", "run", "value", "unit", "evidence"])
        if not exists:
            writer.writeheader()
        writer.writerows(rows)
    failed = [row for row in rows if row["metric"] in {"single_gate", "page_assertion"} and row["value"] != "1"]
    print(f"COLLECTED run={args.run} rows={len(rows)} gate={'0' if failed else '1'}")
    return 0 if not failed else 4


if __name__ == "__main__":
    raise SystemExit(main())
