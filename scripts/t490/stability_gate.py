#!/usr/bin/env python3
"""Recompute the 30-minute Chromium stability gate from immutable evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SCHEMA = "xkernel.stability.v1"
REQUIRED_RELOADS = 10
MIN_DURATION_NS = 1_800_000_000_000


class GateError(ValueError):
    pass


def read_events(path: Path, run_id: str) -> list[dict[str, Any]]:
    if not path.is_file():
        raise GateError(f"stability event file missing: {path}")
    rows: list[dict[str, Any]] = []
    last_seq = 0
    last_time = -1
    event_ids: set[str] = set()
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise GateError(f"invalid event JSON line {line_no}: {exc}") from exc
        if not isinstance(row, dict) or row.get("schema") != SCHEMA or row.get("run_id") != run_id:
            raise GateError(f"line {line_no} has wrong schema/run id")
        if row.get("clock_id") != "t490-host-CLOCK_MONOTONIC":
            raise GateError(f"line {line_no} uses an unexpected clock domain")
        try:
            seq = int(row.get("seq", 0))
            t_ns = int(row.get("t_ns", -1))
        except (TypeError, ValueError) as exc:
            raise GateError(f"line {line_no} has invalid seq/t_ns") from exc
        if seq <= last_seq or t_ns < last_time:
            raise GateError(f"line {line_no} has repeated/out-of-order sequence or time")
        last_seq, last_time = seq, t_ns
        event_id = row.get("event_id")
        if not isinstance(event_id, str) or not event_id or event_id in event_ids:
            raise GateError(f"line {line_no} has missing or duplicate event_id")
        event_ids.add(event_id)
        rows.append(row)
    if not rows:
        raise GateError("stability event file is empty")
    return rows


def verify_image(root: Path, evidence: Path, row: dict[str, Any], profile: str) -> None:
    if row.get("profile") != profile or row.get("strict") is not True or row.get("pass_result") is not True:
        raise GateError(f"page screenshot is not a strict {profile} PASS")
    rel = row.get("capture_path")
    if not isinstance(rel, str) or not rel:
        raise GateError("screenshot capture_path is missing")
    image = (evidence / rel).resolve()
    if not image.is_relative_to(evidence.resolve()) or not image.is_file():
        raise GateError(f"screenshot is missing or outside evidence directory: {rel}")
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    if digest != row.get("sha256"):
        raise GateError(f"screenshot SHA-256 mismatch: {rel}")
    checker = root / "scripts/t490/ppm_assert.py"
    result = subprocess.run(
        [sys.executable, str(checker), str(image), "--profile", profile, "--strict", "--quiet"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise GateError(f"screenshot failed recomputed strict pixel check: {rel}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--console-log", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--profile", default="official-index")
    parser.add_argument("--reload-count", type=int, default=10)
    parser.add_argument("--interval-seconds", type=int, default=120)
    parser.add_argument("--heartbeat-seconds", type=int, default=30)
    parser.add_argument("--schedule-tolerance-seconds", type=float, default=10)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()

    evidence = args.evidence.resolve()
    events = read_events(args.events, args.run_id)
    page_ready = [row for row in events if row.get("event") == "page_ready"]
    monitor_end = [row for row in events if row.get("event") == "monitor_end"]
    result_rows = [row for row in events if row.get("event") == "result"]
    if len(page_ready) != 1 or len(monitor_end) != 1 or len(result_rows) != 1:
        raise GateError("expected one page_ready, monitor_end, and result event")
    start_ns = int(page_ready[0]["t_ns"])
    end_ns = int(monitor_end[0]["t_ns"])
    duration_ns = end_ns - start_ns
    if duration_ns < MIN_DURATION_NS:
        raise GateError(f"measured duration {duration_ns / 1e9:.1f}s is below 1800s")
    verify_image(args.root.resolve(), evidence, page_ready[0], args.profile)

    navigations = [row for row in events if row.get("event") == "navigation_requested"]
    verdicts = {row.get("navigation_id"): row for row in events if row.get("event") == "page_verdict"}
    if len(navigations) != args.reload_count:
        raise GateError(f"found {len(navigations)} reload requests, expected {args.reload_count}")
    reload_results = []
    tolerance_ns = int(args.schedule_tolerance_seconds * 1_000_000_000)
    for index, navigation in enumerate(navigations, 1):
        nav_id = navigation.get("navigation_id")
        if nav_id != f"nav-{index:02d}" or navigation.get("action") != "ctrl+r" or navigation.get("transport") != "QMP send-key":
            raise GateError(f"reload {index} was not the recorded real Ctrl+R QMP action")
        scheduled = int(navigation.get("scheduled_t_ns", -1))
        if abs(int(navigation["t_ns"]) - scheduled) > tolerance_ns:
            raise GateError(f"reload {index} missed its two-minute schedule tolerance")
        verdict = verdicts.get(nav_id)
        if verdict is None or verdict.get("pass_result") is not True or verdict.get("strict") is not True:
            raise GateError(f"reload {index} lacks a strict page verdict")
        if verdict.get("profile") != args.profile:
            raise GateError(f"reload {index} used the wrong pixel profile")
        shot = next((row for row in events if row.get("event") == "screendump_verified"
                     and row.get("navigation_id") == nav_id), None)
        if shot is None:
            raise GateError(f"reload {index} has no verified screendump")
        verify_image(args.root.resolve(), evidence, shot, args.profile)
        reload_results.append({
            "navigation_id": nav_id,
            "requested_t_ns": navigation["t_ns"],
            "scheduled_t_ns": scheduled,
            "schedule_slip_ms": (int(navigation["t_ns"]) - scheduled) / 1_000_000,
            "screenshot": shot["capture_path"],
            "sha256": shot["sha256"],
        })

    liveness = [row for row in events if row.get("event") == "host_liveness"
                and start_ns <= int(row["t_ns"]) <= end_ns]
    required_samples = duration_ns // (args.heartbeat_seconds * 1_000_000_000)
    if len(liveness) < required_samples:
        raise GateError(f"host/QMP liveness has {len(liveness)} samples, need at least {required_samples}")
    if any(row.get("running") is not True or row.get("status") != "running" for row in liveness):
        raise GateError("QEMU was not running at every host liveness sample")
    if any(int(later["t_ns"]) - int(earlier["t_ns"]) > 35_000_000_000
           for earlier, later in zip(liveness, liveness[1:])):
        raise GateError("QEMU liveness sampling gap exceeds 35 seconds")
    for index, sample in enumerate(liveness, 1):
        watchdog = sample.get("guest_watchdog", {})
        family = sample.get("guest_family", {})
        if watchdog.get("weston") != "yes" or watchdog.get("chrome") != "yes":
            raise GateError(f"guest Weston/Browser not alive at liveness sample {index}")
        roles = set(family.get("roles", []))
        if not {"browser_child", "zygote_child"}.issubset(roles):
            raise GateError(f"guest Browser/Zygote/Renderer process family missing at sample {index}: {sorted(roles)}")
        if sample.get("guest_watchdog_age_s") is None or float(sample["guest_watchdog_age_s"]) > 35:
            raise GateError(f"guest watchdog sample stale at liveness sample {index}")
        if sample.get("guest_family_age_s") is None or float(sample["guest_family_age_s"]) > 35:
            raise GateError(f"guest process family sample stale at liveness sample {index}")

    exits = [row for row in events if row.get("event") == "guest_process_exit"
             and start_ns <= int(row["t_ns"]) <= end_ns]
    relevant_exits = [row for row in exits if row.get("kind") in {"browser_child", "zygote_child"}]
    if relevant_exits:
        raise GateError(f"observed {len(relevant_exits)} Browser/Zygote/Renderer process exits")
    exceptions = [row for row in events if row.get("event") == "guest_exception"
                  and start_ns <= int(row["t_ns"]) <= end_ns]
    if exceptions:
        raise GateError(f"observed {len(exceptions)} guest exception markers")

    if not args.console_log.is_file():
        raise GateError(f"console log missing: {args.console_log}")
    console = args.console_log.read_text(encoding="utf-8", errors="replace")
    fatal_patterns = [r"out of memory", r"oom-kill", r"killed process", r"kernel panic"]
    fatal_hits = [pattern for pattern in fatal_patterns if re.search(pattern, console, re.I)]
    if fatal_hits:
        raise GateError(f"fatal/OOM/Wayland markers found in console: {fatal_hits}")

    payload = {
        "schema": "xkernel.stability-gate.v1",
        "run_id": args.run_id,
        "pass": True,
        "mode": "default-multiprocess",
        "guest_memory": "2g (platform.env default)",
        "measured_seconds": duration_ns / 1_000_000_000,
        "scheduled_reload_count": len(navigations),
        "strict_reload_passes": len(reload_results),
        "qemu_liveness_samples": len(liveness),
        "guest_process_exits": len(exits),
        "unclassified_guest_process_exits": sum(row.get("kind") == "unknown" for row in exits),
        "guest_exceptions": len(exceptions),
        "reloads": reload_results,
        "evidence": {
            "events": str(args.events.resolve()),
            "console_log": str(args.console_log.resolve()),
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("x", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"STABILITY_GATE_FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
