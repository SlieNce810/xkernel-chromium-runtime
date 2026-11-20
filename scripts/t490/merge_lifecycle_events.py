#!/usr/bin/env python3
"""Merge guest lifecycle probes and QMP page verdicts into one monotonic ledger.

Guest sampler/preload records already use ``LINUX_CLOCK_MONOTONIC``. QMP
records use the T490 host monotonic clock; this tool maps only page-verdict and
screendump timestamps through bracketing guest clock-sync records. It never
invents a missing browser, renderer, navigation, or frame event. Incomplete
ledgers are written with ``valid=false`` for diagnosis and rejected by the
metric collector.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

SCHEMA = "xkernel.browser.lifecycle.v1"
GUEST_CLOCK = "LINUX_CLOCK_MONOTONIC"


class MergeError(ValueError):
    """Input records cannot be combined without fabricating provenance."""


def _screendump_sha256(evidence_dir: Path, capture_path: str) -> tuple[str, str]:
    relative_path = Path(capture_path)
    root = evidence_dir.resolve()
    resolved_capture = (root / relative_path).resolve()
    if not resolved_capture.is_relative_to(root):
        raise MergeError("screendump capture path escapes the evidence directory")
    if resolved_capture.is_file():
        return hashlib.sha256(resolved_capture.read_bytes()).hexdigest(), "local-file"

    manifest_path = root / "ppm-sha256.txt"
    if manifest_path.is_file():
        normalized = relative_path.as_posix()
        for line_number, line in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), 1):
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1].replace("\\", "/") == normalized:
                digest = parts[0].lower()
                if len(digest) == 64 and all(ch in "0123456789abcdef" for ch in digest):
                    return digest, "ppm-sha256-manifest"
                raise MergeError(f"invalid PPM SHA-256 on manifest line {line_number}")
    raise MergeError(f"screendump capture file and PPM hash are missing: {capture_path}")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise MergeError(f"event file is missing: {path}")
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise MergeError(f"invalid JSON at {path}:{line_number}: {exc}") from exc
        if not isinstance(value, dict):
            raise MergeError(f"record at {path}:{line_number} is not an object")
        rows.append(value)
    return rows


def read_mp_events(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    if not path.is_file():
        raise MergeError(f"Chromium console file is missing: {path}")
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            marker = raw_line.find("MP_EVENT ")
            if marker < 0:
                continue
            try:
                event = json.loads(raw_line[marker + len("MP_EVENT "):].strip())
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if event.get("event") not in {"zygote-observed", "renderer-observed"}:
                continue
            try:
                t_ns = int(round(float(event["timestamp_monotonic"]) * 1_000_000_000))
                pid = int(event["pid"])
                ppid = int(event.get("ppid", 0))
            except (KeyError, TypeError, ValueError):
                continue
            if t_ns <= 0 or pid <= 0:
                continue
            events.append({
                "line": line_number,
                "t_ns": t_ns,
                "pid": pid,
                "ppid": ppid,
                "role": str(event.get("process_role", "")),
                "event": str(event["event"]),
                "source": str(event.get("observation_source", "")),
            })
    return events


def _positive_ns(value: Any, label: str) -> int:
    if isinstance(value, bool):
        raise MergeError(f"{label} must be a positive integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise MergeError(f"{label} must be a positive integer") from exc
    if result <= 0:
        raise MergeError(f"{label} must be positive")
    return result


def _read_clock_sync(stability: list[dict[str, Any]], run_id: str) -> list[tuple[int, int]]:
    pairs: list[tuple[int, int]] = []
    for row in stability:
        if row.get("event") != "clock_sync":
            continue
        if row.get("run_id") != run_id:
            raise MergeError("clock-sync run_id does not match this run")
        if row.get("schema") != "xkernel.stability.v1":
            raise MergeError("clock-sync schema is not xkernel.stability.v1")
        if row.get("clock_id") != "t490-host-CLOCK_MONOTONIC":
            raise MergeError("clock-sync host clock is not t490-host-CLOCK_MONOTONIC")
        if row.get("guest_clock_id") != GUEST_CLOCK:
            raise MergeError("clock-sync guest clock is not LINUX_CLOCK_MONOTONIC")
        host_ns = _positive_ns(row.get("host_receive_t_ns"), "clock-sync host_receive_t_ns")
        guest_ns = _positive_ns(row.get("guest_t_ns"), "clock-sync guest_t_ns")
        pairs.append((host_ns, guest_ns))
    pairs.sort()
    if len(pairs) < 2:
        raise MergeError("at least two guest/host clock-sync pairs are required")
    if any(pairs[i][0] >= pairs[i + 1][0] or pairs[i][1] >= pairs[i + 1][1]
           for i in range(len(pairs) - 1)):
        raise MergeError("clock-sync pairs are duplicated or not monotonic")
    return pairs


def _map_host_to_guest(host_ns: int, pairs: list[tuple[int, int]]) -> int:
    for (host_a, guest_a), (host_b, guest_b) in zip(pairs, pairs[1:]):
        if host_a <= host_ns <= host_b:
            numerator = (host_ns - host_a) * (guest_b - guest_a)
            return guest_a + (numerator + (host_b - host_a) // 2) // (host_b - host_a)
    raise MergeError(f"host event time {host_ns} is outside guest clock-sync anchors")


def _validate_guest_events(rows: list[dict[str, Any]], run_id: str, source: str) -> None:
    for index, row in enumerate(rows, 1):
        if row.get("schema") != SCHEMA or row.get("run_id") != run_id:
            raise MergeError(f"{source} event {index} has the wrong schema or run_id")
        if row.get("clock_id") != GUEST_CLOCK:
            raise MergeError(f"{source} event {index} has the wrong clock_id")
        _positive_ns(row.get("t_ns"), f"{source} event {index} t_ns")
        if not isinstance(row.get("event"), str) or not row["event"]:
            raise MergeError(f"{source} event {index} has no event name")


def merge(
    memory_events_path: Path,
    probe_events_path: Path,
    stability_events_path: Path,
    console_log_path: Path | None,
    evidence_dir: Path,
    output_path: Path,
    summary_path: Path,
    run_id: str,
    navigation_id: str,
    sampling_interval_ms: int,
) -> dict[str, Any]:
    memory_events = read_jsonl(memory_events_path)
    probe_events = read_jsonl(probe_events_path) if probe_events_path.is_file() else []
    stability_events = read_jsonl(stability_events_path)
    mp_events = read_mp_events(console_log_path)
    if sampling_interval_ms <= 0:
        raise MergeError("sampling_interval_ms must be positive")
    for index, row in enumerate(stability_events, 1):
        if row.get("schema") != "xkernel.stability.v1" or row.get("run_id") != run_id:
            raise MergeError(f"stability event {index} has the wrong schema or run_id")
        if row.get("clock_id") != "t490-host-CLOCK_MONOTONIC":
            raise MergeError(f"stability event {index} has the wrong host clock_id")
    _validate_guest_events(memory_events, run_id, "memory")
    _validate_guest_events(probe_events, run_id, "preload")
    sync_pairs = _read_clock_sync(stability_events, run_id)

    events = [dict(row) for row in memory_events]
    events.extend(
        dict(row) for row in probe_events
        if row.get("event") != "renderer_create_requested"
    )
    browser_instances = {
        row.get("process_instance")
        for row in events
        if row.get("event") == "process_started" and row.get("role") == "browser"
    }
    process_role_observations = 0
    unmatched_process_role_observations: list[str] = []
    process_starts_by_pid: dict[int, list[dict[str, Any]]] = {}
    process_exits_by_instance: dict[str, int] = {}
    for row in memory_events:
        if row.get("event") == "process_started":
            process_starts_by_pid.setdefault(int(row["pid"]), []).append(row)
        elif row.get("event") == "process_exited":
            process_exits_by_instance[str(row.get("process_instance", ""))] = int(row["t_ns"])
    for observation in mp_events:
        process_role_observations += 1
        candidates = [
            row for row in process_starts_by_pid.get(observation["pid"], [])
            if int(row["t_ns"]) <= observation["t_ns"]
            and process_exits_by_instance.get(str(row.get("process_instance", "")), 1 << 63)
                > observation["t_ns"]
        ]
        if not candidates:
            unmatched_process_role_observations.append(
                f"MP_EVENT {observation['event']} PID {observation['pid']} at {observation['t_ns']} has no live process instance"
            )
            continue
        process = max(candidates, key=lambda row: int(row["t_ns"]))
        if process.get("role") == observation["role"]:
            continue
        events.append({
            "schema": SCHEMA,
            "run_id": run_id,
            "clock_id": GUEST_CLOCK,
            "t_ns": observation["t_ns"],
            "event": "process_role_changed",
            "pid": observation["pid"],
            "ppid": observation["ppid"],
            "process_instance": str(process["process_instance"]),
            "parent_process_instance": process.get("parent_process_instance"),
            "role": observation["role"],
            "source": "mp-event-process-observer",
            "observation_event": observation["event"],
        })
    renderers = [
        row for row in events
        if row.get("event") == "renderer_ready" and row.get("navigation_id") == navigation_id
    ]
    frames = [
        row for row in events
        if row.get("event") == "first_valid_frame" and row.get("navigation_id") == navigation_id
    ]
    page_ready = [
        row for row in stability_events
        if row.get("event") == "page_ready"
        and row.get("navigation_id") == navigation_id
        and row.get("pass_result") is True
    ]
    screendumps = [
        row for row in stability_events
        if row.get("event") == "screendump_verified"
        and row.get("navigation_id") == navigation_id
        and row.get("pass_result") is True
    ]
    errors: list[str] = []
    if len(browser_instances) != 1:
        errors.append(f"expected one observed browser process instance, found {len(browser_instances)}")
    if len([row for row in events if row.get("event") == "browser_main_loop_ready"]) != 1:
        errors.append("expected one browser_main_loop_ready event")
    navs = [row for row in events if row.get("event") == "navigation_requested"
            and row.get("navigation_id") == navigation_id]
    if len(navs) != 1:
        errors.append(f"expected one navigation_requested for {navigation_id}, found {len(navs)}")
    nav_time_ns = int(navs[0]["t_ns"]) if len(navs) == 1 else None
    if len(page_ready) != 1:
        errors.append(f"expected one passing page_ready for {navigation_id}, found {len(page_ready)}")
    if not screendumps:
        errors.append(f"no passing screendump_verified event for {navigation_id}")
    if len(frames) != 1:
        errors.append(f"expected one first_valid_frame for {navigation_id}, found {len(frames)}")

    frame = frames[0] if len(frames) == 1 else None
    renderer_id_from_frame = str(frame.get("renderer_id", "")) if frame else ""
    renderer = next((row for row in renderers
                     if row.get("renderer_id") == renderer_id_from_frame), None)
    if renderer is None and len(renderers) == 1:
        renderer = renderers[0]
    if renderer is None:
        errors.append(
            f"cannot select one renderer_ready for {navigation_id} without a matching first frame"
        )
    renderer_id = str(renderer.get("renderer_id", "")) if renderer else ""
    renderer_pid = renderer.get("pid") if renderer else None
    renderer_instance = str(renderer.get("process_instance", "")) if renderer else ""
    if frame and renderer:
        if frame.get("renderer_id") != renderer_id or frame.get("pid") != renderer_pid or frame.get("process_instance") != renderer_instance:
            errors.append("first_valid_frame does not match the selected renderer_ready")

    browser_instance = next(iter(browser_instances), None) if len(browser_instances) == 1 else None
    browser_process = next((row for row in events
                            if row.get("event") == "process_started"
                            and row.get("process_instance") == browser_instance), None)
    fork_events = [row for row in probe_events
                   if row.get("event") in {"zygote_fork_boundary", "renderer_create_requested"}]
    paired_renderer_requests = 0
    unpaired_renderer_ready = 0
    for renderer_ready in renderers:
        request_id = renderer_ready.get("request_id")
        child_pid = renderer_ready.get("pid")
        candidates = [row for row in fork_events
                      if row.get("request_id") == request_id
                      and int(row.get("child_pid", -1)) == int(child_pid)]
        candidates = [row for row in candidates
                      if nav_time_ns is not None and int(row.get("t_ns", -1)) >= nav_time_ns
                      and int(row.get("t_ns", -1)) < int(renderer_ready.get("t_ns", 0))]
        if not candidates or browser_process is None:
            unpaired_renderer_ready += 1
            continue
        request = min(candidates, key=lambda row: int(row["t_ns"]))
        events.append({
            "schema": SCHEMA,
            "run_id": run_id,
            "clock_id": GUEST_CLOCK,
            "t_ns": int(request["t_ns"]),
            "event": "renderer_create_requested",
            "pid": int(browser_process["pid"]),
            "ppid": int(browser_process.get("ppid", 0)),
            "process_instance": browser_instance,
            "role": "browser",
            "navigation_id": navigation_id,
            "request_id": str(request_id),
            "renderer_child_pid": int(child_pid),
            "source": "paired-zygote-fork-boundary",
        })
        paired_renderer_requests += 1
    if unpaired_renderer_ready:
        errors.append(f"{unpaired_renderer_ready} renderer_ready events lack a post-navigation matching zygote fork boundary")
    errors.extend(unmatched_process_role_observations)

    for row in page_ready:
        try:
            host_ns = _positive_ns(row.get("t_ns"), "page_ready host t_ns")
            guest_ns = _map_host_to_guest(host_ns, sync_pairs)
        except MergeError as exc:
            errors.append(f"page_ready clock mapping failed: {exc}")
            continue
        capture_path = str(row.get("capture_path", ""))
        events.append({
            "schema": SCHEMA,
            "run_id": run_id,
            "clock_id": GUEST_CLOCK,
            "t_ns": guest_ns,
            "event": "page_verdict",
            "navigation_id": navigation_id,
            "renderer_id": renderer_id,
            "pid": renderer_pid,
            "process_instance": renderer_instance,
            "pass": True,
            "strict": True,
            "profile": str(row.get("profile", "")),
            "source": "qmp-strict-screendump",
            "capture_path": capture_path,
        })
    for row in screendumps:
        try:
            host_ns = _positive_ns(row.get("t_ns"), "screendump_verified host t_ns")
            guest_ns = _map_host_to_guest(host_ns, sync_pairs)
        except MergeError as exc:
            errors.append(f"screendump clock mapping failed: {exc}")
            continue
        capture_path = str(row.get("capture_path", ""))
        try:
            capture_sha256, capture_hash_source = _screendump_sha256(evidence_dir, capture_path)
        except MergeError as exc:
            errors.append(str(exc))
            continue
        events.append({
            "schema": SCHEMA,
            "run_id": run_id,
            "clock_id": GUEST_CLOCK,
            "t_ns": guest_ns,
            "event": "screendump_verified",
            "navigation_id": navigation_id,
            "renderer_id": renderer_id,
            "pass": True,
            "profile": str(row.get("profile", "")),
            "capture_path": capture_path,
            "sha256": capture_sha256,
            "sha256_source": capture_hash_source,
            "sampling_interval_ms": sampling_interval_ms,
            "source": "qmp-clock-sync-mapped",
        })

    priority = {
        "browser_launch_requested": 0,
        "process_started": 1,
        "browser_main_loop_ready": 2,
        "navigation_requested": 3,
        "renderer_create_requested": 4,
        "renderer_ready": 5,
        "first_valid_frame": 6,
        "page_verdict": 7,
        "screendump_verified": 8,
        "process_exited": 9,
        "memory_sampling_finished": 10,
    }
    events.sort(key=lambda row: (_positive_ns(row.get("t_ns"), "merged t_ns"),
                                 priority.get(str(row.get("event")), 20)))
    last_ns = -1
    for seq, row in enumerate(events, 1):
        t_ns = int(row["t_ns"])
        if t_ns < last_ns:
            errors.append("merged event timestamps moved backwards")
            break
        last_ns = t_ns
        row["seq"] = seq
        row["event_id"] = f"{run_id}:{seq}"

    if output_path.exists() or summary_path.exists():
        raise MergeError("refusing to overwrite lifecycle merge outputs")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("x", encoding="utf-8", newline="\n") as stream:
        for row in events:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")

    host_times = [host for host, _guest in sync_pairs]
    guest_times = [guest for _host, guest in sync_pairs]
    summary = {
        "schema": "xkernel.lifecycle-merge.v1",
        "run_id": run_id,
        "valid": not errors,
        "errors": errors,
        "lifecycle_events": len(events),
        "probe_events": len(probe_events),
        "mp_process_role_observations": process_role_observations,
        "unmatched_mp_process_role_observations": len(unmatched_process_role_observations),
        "stability_clock_sync_anchors": len(sync_pairs),
        "clock_mapping": {
            "from": "t490-host-CLOCK_MONOTONIC",
            "to": GUEST_CLOCK,
            "method": "linear interpolation between adjacent guest clock-sync receipts",
            "host_sync_span_ns": host_times[-1] - host_times[0],
            "guest_sync_span_ns": guest_times[-1] - guest_times[0],
            "uncertainty_bound_ns": None,
            "uncertainty_note": "serial receive latency is not independently measured; screenshot time remains a conservative sampled upper bound",
        },
        "browser_process_instances": sorted(instance for instance in browser_instances if instance),
        "renderer_instances": sorted({str(row.get("process_instance")) for row in renderers}),
        "paired_renderer_create_requests": paired_renderer_requests,
        "unpaired_renderer_ready_events": unpaired_renderer_ready,
        "first_valid_frame_events": len(frames),
        "output": str(output_path.resolve()),
    }
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    with summary_path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--memory-events", type=Path, required=True)
    parser.add_argument("--probe-events", type=Path, required=True)
    parser.add_argument("--stability-events", type=Path, required=True)
    parser.add_argument("--console-log", type=Path,
                        help="optional raw console log; joins MP_EVENT process-role observations by PID instance")
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--navigation-id", default="nav-00")
    parser.add_argument("--sampling-interval-ms", type=int, default=30000)
    args = parser.parse_args()
    try:
        summary = merge(
            args.memory_events, args.probe_events, args.stability_events,
            args.console_log, args.evidence_dir, args.out, args.summary, args.run_id,
            args.navigation_id, args.sampling_interval_ms,
        )
    except (MergeError, OSError, ValueError) as exc:
        print(f"LIFECYCLE_MERGE_FAIL: {exc}", file=sys.stderr)
        return 2
    print("LIFECYCLE_MERGED " + json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0 if summary["valid"] else 4


if __name__ == "__main__":
    raise SystemExit(main())
