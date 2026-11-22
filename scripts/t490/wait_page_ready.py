#!/usr/bin/env python3
"""Wait until a live QEMU session shows the expected page before injecting input.

The probe only uses QMP ``screendump`` plus the repository's PPM assertions.
It never injects input and never changes the page.  This keeps "wait for the
page" separate from "drive the page", so input evidence cannot be produced
against a blank desktop or a WARMUP frame.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from qmp_input import QmpClient, QmpError


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True,
                        help="QMP Unix socket or tcp://host:port")
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--assert-script", required=True, type=Path)
    parser.add_argument("--profile", default="official-interaction")
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--poll", type=float, default=10.0)
    parser.add_argument("--connect-timeout", type=float, default=120.0)
    return parser.parse_args()


def ready_from_ppm(ppm: Path, assert_script: Path, profile: str,
                   json_path: Path) -> bool:
    command = [
        sys.executable, str(assert_script), str(ppm),
        "--profile", profile, "--strict", "--quiet",
        "--json", str(json_path),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return False
    try:
        report = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return int(report.get("strict_fail_count", 1)) == 0


def main() -> int:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    event_log = args.out_dir / "ready-probe.jsonl"
    client = QmpClient(args.socket, event_log, qmp_send_key=True)
    deadline = time.monotonic() + args.timeout
    attempt = 0
    try:
        client.connect(args.connect_timeout)
        while time.monotonic() < deadline:
            attempt += 1
            ppm = args.out_dir / f"ready-{attempt:03d}.ppm"
            json_path = args.out_dir / f"ready-{attempt:03d}.json"
            try:
                client.screendump(ppm)
            except (OSError, QmpError) as exc:
                client._record("readiness-error", {
                    "attempt": attempt,
                    "error": str(exc),
                })
                time.sleep(args.poll)
                continue
            if ready_from_ppm(ppm, args.assert_script, args.profile, json_path):
                client._record("readiness-result", {
                    "ok": True,
                    "attempt": attempt,
                    "ppm": str(ppm),
                })
                print(f"PAGE_READY {ppm}")
                return 0
            client._record("readiness-result", {
                "ok": False,
                "attempt": attempt,
                "ppm": str(ppm),
            })
            time.sleep(args.poll)
        client._record("readiness-result", {"ok": False, "error": "timeout"})
        print("PAGE_READY_TIMEOUT", file=sys.stderr)
        return 4
    except (OSError, QmpError) as exc:
        print(f"wait_page_ready: {exc}", file=sys.stderr)
        return 2
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
