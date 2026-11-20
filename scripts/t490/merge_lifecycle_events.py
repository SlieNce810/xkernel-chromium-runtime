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
    events.extend(dict(row) for row in probe_events)
    browser_instances = {
        row.get("process_instance")
        for row in events
        if row.get("event") == "process_started" and row.get("role") == "browser"
    }
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

    for row in page_ready:
        host_ns = _positive_ns(row.get("t_ns"), "page_ready host t_ns")
        guest_ns = _map_host_to_guest(host_ns, sync_pairs)
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
        host_ns = _positive_ns(row.get("t_ns"), "screendump_verified host t_ns")
        guest_ns = _map_host_to_guest(host_ns, sync_pairs)
        capture_path = str(row.get("capture_path", ""))
        relative_path = Path(capture_path)
        resolved_capture = (evidence_dir / relative_path).resolve()
        if not resolved_capture.is_relative_to(evidence_dir.resolve()):
            errors.append("screendump capture path escapes the evidence directory")
            continue
        if not resolved_capture.is_file():
            errors.append(f"screendump capture file is missing: {capture_path}")
            continue
        capture_sha256 = hashlib.sha256(resolved_capture.read_bytes()).hexdigest()
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
            args.evidence_dir, args.out, args.summary, args.run_id,
            args.navigation_id, args.sampling_interval_ms,
        )
    except (MergeError, OSError, ValueError) as exc:
        print(f"LIFECYCLE_MERGE_FAIL: {exc}", file=sys.stderr)
        return 2
    print("LIFECYCLE_MERGED " + json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0 if summary["valid"] else 4


if __name__ == "__main__":
    raise SystemExit(main())
