#!/usr/bin/env python3
"""Validate and collect one Chromium lifecycle/RSS-PSS-USS measurement run.

The original positional interface is retained::

    python3 scripts/collect_metrics.py EVIDENCE --run RUN_ID --csv RAW.csv

An accepted sample needs a same-clock lifecycle ledger and one-second process
tree memory samples. Old marker-only evidence remains readable as a diagnostic
but is intentionally not admitted to the performance CSV.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


EVENT_SCHEMA = "xkernel.browser.lifecycle.v1"
METRIC_COLUMNS = ["metric", "run", "value", "unit", "evidence"]
MEMORY_COLUMNS = {
    "run_id", "clock_id", "sample_id", "t_ns", "pid", "ppid", "process_instance",
    "rss_kb", "pss_kb", "uss_kb",
}
REQUIRED_METRICS = {
    "browser_startup_ms",
    "page_first_frame_ms",
    "page_first_screendump_upper_bound_ms",
    "renderer_create_ms",
    "peak_chromium_rss_kb",
    "peak_chromium_pss_kb",
    "peak_chromium_uss_kb",
}


class InvalidSample(ValueError):
    pass


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool):
        raise InvalidSample(f"{label} must be an integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise InvalidSample(f"{label} must be an integer") from exc
    if result < 0 or str(result) != str(value):
        raise InvalidSample(f"{label} must be a non-negative integer")
    return result


def _nonempty(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidSample(f"{label} is missing")
    return value.strip()


def read_events(path: Path, expected_run: str) -> list[dict[str, Any]]:
    if not path.is_file():
        raise InvalidSample(f"lifecycle event file missing: {path}")
    rows: list[dict[str, Any]] = []
    event_ids: set[str] = set()
    last_seq = -1
    last_time = -1
    observed_run: str | None = None
    observed_clock: str | None = None
    for line_number, raw in enumerate(path.read_text(encoding="utf-8", errors="strict").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise InvalidSample(f"invalid lifecycle JSON on line {line_number}: {exc}") from exc
        if not isinstance(row, dict):
            raise InvalidSample(f"lifecycle line {line_number} must be a JSON object")
        if row.get("schema") != EVENT_SCHEMA:
            raise InvalidSample(f"line {line_number}: schema must be {EVENT_SCHEMA}")
        run_id = _nonempty(row.get("run_id"), f"line {line_number} run_id")
        if observed_run is None:
            observed_run = run_id
        elif run_id != observed_run:
            raise InvalidSample(f"mixed run identifiers: {observed_run!r} and {run_id!r}")
        if run_id != expected_run:
            raise InvalidSample(f"event run_id {run_id!r} does not match --run {expected_run!r}")
        clock_id = _nonempty(row.get("clock_id"), f"line {line_number} clock_id")
        if observed_clock is None:
            observed_clock = clock_id
        elif clock_id != observed_clock:
            raise InvalidSample(f"mixed event clock domains: {observed_clock!r} and {clock_id!r}")
        seq = _positive_int(row.get("seq"), f"line {line_number} seq")
        if seq <= last_seq:
            raise InvalidSample(f"event sequence is repeated or out of order at line {line_number}")
        last_seq = seq
        t_ns = _positive_int(row.get("t_ns"), f"line {line_number} t_ns")
        if t_ns < last_time:
            raise InvalidSample(f"event time moved backwards at line {line_number}")
        last_time = t_ns
        event_id = _nonempty(row.get("event_id"), f"line {line_number} event_id")
        if event_id in event_ids:
            raise InvalidSample(f"duplicate event_id: {event_id}")
        event_ids.add(event_id)
        _nonempty(row.get("event"), f"line {line_number} event")
        row["_line"] = line_number
        row["_t_ns"] = t_ns
        rows.append(row)
    if not rows:
        raise InvalidSample("lifecycle event file is empty")
    return rows


def _event_rows(events: list[dict[str, Any]], name: str) -> list[dict[str, Any]]:
    return [row for row in events if row["event"] == name]


def _validate_processes(events: list[dict[str, Any]]) -> tuple[dict[str, dict[str, Any]], str]:
    processes: dict[str, dict[str, Any]] = {}
    live_by_pid: dict[int, str] = {}
    for event in events:
        kind = event["event"]
        if kind == "process_started":
            pid = _positive_int(event.get("pid"), f"line {event['_line']} pid")
            if pid == 0:
                raise InvalidSample(f"line {event['_line']}: PID 0 is invalid")
            instance = _nonempty(event.get("process_instance"), f"line {event['_line']} process_instance")
            if instance in processes:
                raise InvalidSample(f"duplicate process_instance: {instance}")
            if pid in live_by_pid:
                raise InvalidSample(
                    f"PID reuse without an observed exit: pid={pid}, "
                    f"old={live_by_pid[pid]}, new={instance}"
                )
            role = _nonempty(event.get("role"), f"line {event['_line']} process role")
            ppid_raw = event.get("ppid")
            ppid = None if ppid_raw is None else _positive_int(ppid_raw, f"line {event['_line']} ppid")
            parent_raw = event.get("parent_process_instance")
            parent = parent_raw.strip() if isinstance(parent_raw, str) and parent_raw.strip() else None
            if parent and parent not in processes:
                raise InvalidSample(f"line {event['_line']}: parent process is not known: {parent}")
            if parent:
                parent_process = processes[parent]
                if parent_process["pid"] != ppid:
                    raise InvalidSample(f"line {event['_line']}: parent PID/instance do not match")
                if parent_process["end"] is not None and parent_process["end"] <= event["_t_ns"]:
                    raise InvalidSample(f"line {event['_line']}: child started after parent exit")
            if not parent and role != "browser" and ppid not in (None, 0):
                raise InvalidSample(f"line {event['_line']}: non-root process lacks parent identity")
            processes[instance] = {
                "pid": pid,
                "ppid": ppid,
                "parent": parent,
                "role": role,
                "start": event["_t_ns"],
                "end": None,
            }
            live_by_pid[pid] = instance
        elif kind == "process_exited":
            pid = _positive_int(event.get("pid"), f"line {event['_line']} pid")
            instance = _nonempty(event.get("process_instance"), f"line {event['_line']} process_instance")
            process = processes.get(instance)
            if process is None or process["pid"] != pid or process["end"] is not None:
                raise InvalidSample(f"line {event['_line']}: unmatched process exit for {pid}/{instance}")
            if event["_t_ns"] <= process["start"]:
                raise InvalidSample(f"line {event['_line']}: process exit precedes or equals process start")
            process["end"] = event["_t_ns"]
            live_by_pid.pop(pid, None)

    browser_roots = [instance for instance, process in processes.items() if process["role"] == "browser" and process["parent"] is None]
    if len(browser_roots) != 1:
        raise InvalidSample(f"expected one browser root process, found {len(browser_roots)}")
    return processes, browser_roots[0]


def _is_descendant(instance: str, root: str, processes: dict[str, dict[str, Any]]) -> bool:
    seen: set[str] = set()
    current: str | None = instance
    while current:
        if current == root:
            return True
        if current in seen:
            raise InvalidSample(f"process parent cycle at {current}")
        seen.add(current)
        process = processes.get(current)
        if process is None:
            return False
        current = process["parent"]
    return False


def _validate_lifecycle(events: list[dict[str, Any]], processes: dict[str, dict[str, Any]], browser_instance: str) -> dict[str, Any]:
    launches = _event_rows(events, "browser_launch_requested")
    browser_ready = _event_rows(events, "browser_main_loop_ready")
    navs = _event_rows(events, "navigation_requested")
    if len(launches) != 1:
        raise InvalidSample(f"expected one browser_launch_requested event, found {len(launches)}")
    if len(browser_ready) != 1:
        raise InvalidSample(f"expected one browser_main_loop_ready event, found {len(browser_ready)}")
    if len(navs) != 1:
        raise InvalidSample(f"expected one navigation_requested event, found {len(navs)}")
    launch = launches[0]
    ready = browser_ready[0]
    if ready["_t_ns"] <= launch["_t_ns"]:
        raise InvalidSample("browser main loop ready must follow launch request")
    if _nonempty(ready.get("process_instance"), "browser ready process_instance") != browser_instance:
        raise InvalidSample("browser ready event is not from the browser root process")
    if _positive_int(ready.get("pid"), "browser ready pid") != processes[browser_instance]["pid"]:
        raise InvalidSample("browser ready PID does not match browser root")
    browser_start = processes[browser_instance]["start"]
    if browser_start < launch["_t_ns"]:
        raise InvalidSample("browser process started before browser launch request")

    nav = navs[0]
    nav_id = _nonempty(nav.get("navigation_id"), "navigation_id")
    nav_time = nav["_t_ns"]
    if nav_time < ready["_t_ns"]:
        raise InvalidSample("navigation request precedes browser main loop readiness")

    create_requests: dict[str, dict[str, Any]] = {}
    for request in _event_rows(events, "renderer_create_requested"):
        request_id = _nonempty(request.get("request_id"), "renderer request_id")
        if request_id in create_requests:
            raise InvalidSample(f"duplicate renderer request_id: {request_id}")
        if request.get("navigation_id") != nav_id:
            continue
        if request["_t_ns"] < nav_time:
            raise InvalidSample("renderer create request precedes its navigation")
        create_requests[request_id] = request

    renderer_ready_by_id: dict[str, dict[str, Any]] = {}
    selected_renderer: dict[str, Any] | None = None
    for renderer_ready in _event_rows(events, "renderer_ready"):
        request_id = _nonempty(renderer_ready.get("request_id"), "renderer ready request_id")
        request = create_requests.get(request_id)
        if request is None:
            if renderer_ready.get("navigation_id") == nav_id:
                raise InvalidSample(f"renderer ready has no matching create request: {request_id}")
            continue
        if renderer_ready["_t_ns"] <= request["_t_ns"]:
            raise InvalidSample(f"renderer ready precedes request: {request_id}")
        if renderer_ready.get("navigation_id") != nav_id:
            raise InvalidSample(f"renderer navigation mismatch for request {request_id}")
        renderer_id = _nonempty(renderer_ready.get("renderer_id"), "renderer_id")
        if renderer_id in renderer_ready_by_id:
            raise InvalidSample(f"duplicate renderer_ready for renderer {renderer_id}")
        instance = _nonempty(renderer_ready.get("process_instance"), "renderer process_instance")
        process = processes.get(instance)
        pid = _positive_int(renderer_ready.get("pid"), "renderer ready pid")
        if process is None or process["pid"] != pid or process["role"] != "renderer":
            raise InvalidSample(f"renderer ready does not match a renderer process: {pid}/{instance}")
        if not _is_descendant(instance, browser_instance, processes):
            raise InvalidSample("renderer is outside the browser process tree")
        resolved = dict(renderer_ready)
        resolved["_request"] = request
        renderer_ready_by_id[renderer_id] = resolved

    frames = _event_rows(events, "first_valid_frame")
    frames = [row for row in frames if row.get("navigation_id") == nav_id]
    if len(frames) != 1:
        raise InvalidSample(f"expected one first_valid_frame for navigation {nav_id}, found {len(frames)}")
    frame = frames[0]
    renderer_id = _nonempty(frame.get("renderer_id"), "first frame renderer_id")
    selected_renderer = renderer_ready_by_id.get(renderer_id)
    if selected_renderer is None:
        raise InvalidSample("first frame renderer has no matching ready event")
    if frame["_t_ns"] <= selected_renderer["_t_ns"]:
        raise InvalidSample("first valid frame precedes renderer ready")
    if _positive_int(frame.get("pid"), "first frame pid") != _positive_int(selected_renderer.get("pid"), "renderer ready pid"):
        raise InvalidSample("first frame PID does not match renderer ready")
    if frame.get("process_instance") != selected_renderer.get("process_instance"):
        raise InvalidSample("first frame process instance does not match renderer ready")
    if frame.get("valid") is not True or not _nonempty(frame.get("source"), "first frame source"):
        raise InvalidSample("first_valid_frame must be marked valid and identify its source")
    if frame["_t_ns"] <= nav_time:
        raise InvalidSample("first valid frame precedes navigation request")

    verdicts = [row for row in _event_rows(events, "page_verdict") if row.get("navigation_id") == nav_id]
    if len(verdicts) != 1:
        raise InvalidSample(f"expected one page_verdict for navigation {nav_id}, found {len(verdicts)}")
    verdict = verdicts[0]
    if verdict.get("renderer_id") != renderer_id or verdict.get("pass") is not True or verdict.get("strict") is not True:
        raise InvalidSample("page verdict is not a strict PASS for the first-frame renderer")
    if verdict["_t_ns"] < frame["_t_ns"]:
        raise InvalidSample("strict page verdict precedes first valid frame")

    shots = [row for row in _event_rows(events, "screendump_verified") if row.get("navigation_id") == nav_id]
    shots = [row for row in shots if row.get("renderer_id") == renderer_id and row["_t_ns"] >= frame["_t_ns"]]
    if not shots:
        raise InvalidSample("no strict screendump cross-check follows the first valid frame")
    shot = min(shots, key=lambda row: row["_t_ns"])
    if shot.get("pass") is not True or shot.get("profile") is None:
        raise InvalidSample("screendump cross-check is not a passing profile result")
    if shot.get("profile") != verdict.get("profile"):
        raise InvalidSample("screendump profile does not match page verdict profile")
    sampling_interval_ms = float(shot.get("sampling_interval_ms", 0))
    if not math.isfinite(sampling_interval_ms) or sampling_interval_ms <= 0:
        raise InvalidSample("screendump sampling_interval_ms must be positive")
    selected_renderer = dict(selected_renderer)
    selected_renderer.update({
        "launch": launch,
        "browser_ready": ready,
        "browser_start": browser_start,
        "navigation": nav,
        "frame": frame,
        "verdict": verdict,
        "shot": shot,
        "renderer_create_request": selected_renderer["_request"],
        "sampling_interval_ms": sampling_interval_ms,
    })
    return selected_renderer


def _verify_screendump(evidence: Path, shot: dict[str, Any], profile: str) -> None:
    if shot.get("profile") != profile:
        raise InvalidSample(f"screendump profile {shot.get('profile')!r} does not match --profile {profile!r}")
    relative = Path(_nonempty(shot.get("capture_path"), "screendump capture_path"))
    image = (evidence / relative).resolve()
    if not image.is_relative_to(evidence.resolve()):
        raise InvalidSample("screendump path escapes the evidence directory")
    if not image.is_file():
        raise InvalidSample(f"screendump file missing: {relative}")
    expected_hash = _nonempty(shot.get("sha256"), "screendump sha256").lower()
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    if digest != expected_hash:
        raise InvalidSample(f"screendump SHA-256 mismatch: {relative}")
    assert_script = Path(__file__).resolve().parent / "t490" / "ppm_assert.py"
    if not assert_script.is_file():
        raise InvalidSample(f"pixel checker missing: {assert_script}")
    result = subprocess.run(
        [sys.executable, str(assert_script), str(image), "--profile", profile, "--strict", "--quiet"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stdout or result.stderr).strip().splitlines()
        raise InvalidSample(f"screendump failed strict pixel check: {detail[-1] if detail else result.returncode}")


def _read_memory(path: Path, expected_run: str, browser_instance: str,
                 processes: dict[str, dict[str, Any]], start_ns: int,
                 page_ready_ns: int, expected_clock: str) -> tuple[list[dict[str, Any]], dict[str, int]]:
    if not path.is_file():
        raise InvalidSample(f"memory sample file missing: {path}")
    groups: dict[str, dict[str, Any]] = {}
    seen_pair: set[tuple[str, str]] = set()
    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        missing = MEMORY_COLUMNS - set(reader.fieldnames or [])
        if missing:
            raise InvalidSample(f"memory CSV columns missing: {', '.join(sorted(missing))}")
        for line_number, row in enumerate(reader, 2):
            run_id = _nonempty(row.get("run_id"), f"memory line {line_number} run_id")
            if run_id != expected_run:
                raise InvalidSample(f"memory line {line_number} has a different run_id: {run_id}")
            clock_id = _nonempty(row.get("clock_id"), f"memory line {line_number} clock_id")
            if clock_id != expected_clock:
                raise InvalidSample(f"memory line {line_number} clock domain {clock_id!r} does not match lifecycle clock {expected_clock!r}")
            sample_id = _nonempty(row.get("sample_id"), f"memory line {line_number} sample_id")
            instance = _nonempty(row.get("process_instance"), f"memory line {line_number} process_instance")
            t_ns = _positive_int(row.get("t_ns"), f"memory line {line_number} t_ns")
            pid = _positive_int(row.get("pid"), f"memory line {line_number} pid")
            ppid = _positive_int(row.get("ppid"), f"memory line {line_number} ppid")
            process = processes.get(instance)
            if process is None or process["pid"] != pid or process["ppid"] != ppid:
                raise InvalidSample(f"memory line {line_number} PID identity mismatch for {pid}/{instance}")
            if not _is_descendant(instance, browser_instance, processes):
                raise InvalidSample(f"memory line {line_number} is outside the Chromium process tree")
            pair = (sample_id, instance)
            if pair in seen_pair:
                raise InvalidSample(f"duplicate memory row for sample/process: {sample_id}/{instance}")
            seen_pair.add(pair)
            values: dict[str, float] = {}
            for metric in ("rss_kb", "pss_kb", "uss_kb"):
                try:
                    value = float(row.get(metric, ""))
                except (TypeError, ValueError) as exc:
                    raise InvalidSample(f"memory line {line_number} has missing {metric}") from exc
                if not math.isfinite(value) or value < 0:
                    raise InvalidSample(f"memory line {line_number} has invalid {metric}")
                values[metric] = value
            group = groups.setdefault(sample_id, {"t_ns": t_ns, "processes": {}, "totals": defaultdict(float)})
            if group["t_ns"] != t_ns:
                raise InvalidSample(f"sample_id {sample_id} maps to multiple timestamps")
            if instance in group["processes"]:
                raise InvalidSample(f"duplicate process in memory sample {sample_id}: {instance}")
            group["processes"][instance] = {"pid": pid, "ppid": ppid}
            for metric, value in values.items():
                group["totals"][metric] += value

    if not groups:
        raise InvalidSample("memory sample CSV is empty")
    ordered = sorted(groups.items(), key=lambda item: item[1]["t_ns"])
    times = [group["t_ns"] for _, group in ordered]
    if len(set(times)) != len(times):
        raise InvalidSample("two sample_id values share one timestamp")
    if any(later <= earlier for earlier, later in zip(times, times[1:])):
        raise InvalidSample("memory sample times are not strictly increasing")
    if times[0] < start_ns or times[0] - start_ns > 1_500_000_000:
        raise InvalidSample("first memory sample is not within 1.5 seconds of Chromium launch")
    required_end = page_ready_ns + 60_000_000_000
    # A guest sampler may continue for a fixed bounded run window because the
    # guest cannot observe the host-side strict page verdict. Only count rows
    # through page_ready + 60 seconds; later rows remain raw evidence but must
    # not inflate the requested peak window.
    ordered = [(sample_id, group) for sample_id, group in ordered if group["t_ns"] <= required_end]
    if not ordered:
        raise InvalidSample("memory sampling has no sample before 60 seconds after page completion")
    times = [group["t_ns"] for _, group in ordered]
    if required_end - times[-1] > 1_500_000_000:
        raise InvalidSample("memory sampling ends more than 1.5 seconds before the required 60-second hold")
    if any(later - earlier > 1_500_000_000 for earlier, later in zip(times, times[1:])):
        raise InvalidSample("memory sampling gap exceeds 1.5 seconds")

    for sample_id, group in ordered:
        timestamp = group["t_ns"]
        active = {
            instance for instance, process in processes.items()
            if process["start"] <= timestamp and (process["end"] is None or timestamp < process["end"])
            and _is_descendant(instance, browser_instance, processes)
        }
        observed = set(group["processes"])
        if active != observed:
            missing = sorted(active - observed)
            extra = sorted(observed - active)
            raise InvalidSample(
                f"memory sample {sample_id} process tree mismatch; missing={missing}, extra={extra}"
            )
        if not any(group["totals"][metric] > 0 for metric in ("rss_kb", "pss_kb", "uss_kb")):
            raise InvalidSample(f"memory sample {sample_id} contains only zero/unavailable values")

    peaks = {
        metric: max(group["totals"][metric] for _, group in ordered)
        for metric in ("rss_kb", "pss_kb", "uss_kb")
    }
    if any(value <= 0 for value in peaks.values()):
        raise InvalidSample("one or more memory metrics are unavailable (zero peak)")
    return [{"sample_id": key, "t_ns": group["t_ns"], **group["totals"]} for key, group in ordered], peaks


def validate_sample(evidence: Path, run_id: str, profile: str,
                    events_path: Path | None = None,
                    memory_path: Path | None = None) -> list[dict[str, str]]:
    evidence = evidence.resolve()
    events_path = events_path or evidence / "lifecycle-events.jsonl"
    memory_path = memory_path or evidence / "memory-samples.csv"
    events = read_events(events_path, run_id)
    processes, browser_instance = _validate_processes(events)
    timeline = _validate_lifecycle(events, processes, browser_instance)
    _verify_screendump(evidence, timeline["shot"], profile)
    memory, peaks = _read_memory(
        memory_path,
        run_id,
        browser_instance,
        processes,
        timeline["browser_start"],
        timeline["verdict"]["_t_ns"],
        events[0]["clock_id"],
    )
    startup_ms = (timeline["browser_ready"]["_t_ns"] - timeline["launch"]["_t_ns"]) / 1_000_000
    frame_ms = (timeline["frame"]["_t_ns"] - timeline["navigation"]["_t_ns"]) / 1_000_000
    screen_ms = (timeline["shot"]["_t_ns"] - timeline["navigation"]["_t_ns"]) / 1_000_000
    renderer_ms = (timeline["_t_ns"] - timeline["renderer_create_request"]["_t_ns"]) / 1_000_000
    if min(startup_ms, frame_ms, screen_ms, renderer_ms) <= 0:
        raise InvalidSample("one or more lifecycle durations are not positive")
    values = {
        "browser_startup_ms": (startup_ms, "ms"),
        "page_first_frame_ms": (frame_ms, "ms"),
        "page_first_screendump_upper_bound_ms": (screen_ms, "ms"),
        "renderer_create_ms": (renderer_ms, "ms"),
        "peak_chromium_rss_kb": (peaks["rss_kb"], "kB"),
        "peak_chromium_pss_kb": (peaks["pss_kb"], "kB"),
        "peak_chromium_uss_kb": (peaks["uss_kb"], "kB"),
        "memory_sample_count": (len(memory), "samples"),
        "memory_hold_after_page_seconds": (60, "s"),
        "screendump_sampling_interval_ms": (timeline["sampling_interval_ms"], "ms"),
    }
    return [
        {"metric": name, "run": run_id, "value": f"{value:.6f}", "unit": unit, "evidence": str(evidence)}
        for name, (value, unit) in values.items()
    ]


def check_duplicate_run(csv_path: Path, run_id: str) -> None:
    if not csv_path.exists() or csv_path.stat().st_size == 0:
        return
    with csv_path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        required = {"metric", "run", "value", "unit", "evidence"}
        if required - set(reader.fieldnames or []):
            raise InvalidSample("output CSV does not use the established metric/run/value/unit/evidence header")
        for row in reader:
            if row.get("run", "").strip() == run_id:
                raise InvalidSample(f"duplicate run identifier already exists in output CSV: {run_id}")


def write_rows(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists() and path.stat().st_size > 0
    with path.open("a", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=METRIC_COLUMNS)
        if not exists:
            writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--run", required=True, help="unique run identifier; must match every input record")
    parser.add_argument("--csv", dest="csv_path", type=Path, required=True, help="append valid rows to this raw CSV")
    parser.add_argument("--profile", default="official-index")
    parser.add_argument("--events", type=Path, help="default: EVIDENCE/lifecycle-events.jsonl")
    parser.add_argument("--memory-samples", type=Path, help="default: EVIDENCE/memory-samples.csv")
    parser.add_argument("--validation-json", type=Path, help="optional validation result output")
    args = parser.parse_args()

    result: dict[str, Any] = {"schema": "xkernel.metrics-validation.v1", "run": args.run, "valid": False, "errors": []}
    try:
        check_duplicate_run(args.csv_path, args.run)
        rows = validate_sample(args.evidence, args.run, args.profile, args.events, args.memory_samples)
        missing = REQUIRED_METRICS - {row["metric"] for row in rows}
        if missing:
            raise InvalidSample(f"required metrics missing: {', '.join(sorted(missing))}")
        write_rows(args.csv_path, rows)
        result.update({"valid": True, "metrics": rows, "raw_csv": str(args.csv_path.resolve())})
        print(f"METRICS_VALID run={args.run} metrics={len(REQUIRED_METRICS)} rows={len(rows)}")
    except (InvalidSample, OSError, ValueError, subprocess.SubprocessError) as exc:
        result["errors"].append(str(exc))
        print(f"METRICS_INVALID run={args.run}: {exc}", file=sys.stderr)
        if args.validation_json is None:
            print(json.dumps(result, ensure_ascii=False, indent=2), file=sys.stderr)
    if args.validation_json:
        args.validation_json.parent.mkdir(parents=True, exist_ok=True)
        args.validation_json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if result["valid"] else 4


if __name__ == "__main__":
    raise SystemExit(main())
