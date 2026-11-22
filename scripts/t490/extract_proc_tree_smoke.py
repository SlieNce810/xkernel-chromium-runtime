#!/usr/bin/env python3
"""Extract and validate the proc-tree guest smoke records from serial output."""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import statistics
import sys
from pathlib import Path
from typing import Any

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CSV_HEADER = "run_id,clock_id,sample_id,t_ns,pid,ppid,process_instance,rss_kb,pss_kb,uss_kb"
TIMING_FIELDS = (
    "tree_snapshot_total_ns",
    "tree_snapshot_resident_walk_ns",
    "tree_snapshot_mapcount_ns",
    "tree_snapshot_rollup_ns",
    "tree_snapshot_format_ns",
    "tree_snapshot_process_count",
    "tree_snapshot_resident_pages",
    "tree_smaps_rollup_read_ns",
    "sample_work_ns",
)
EXTENDED_CSV_HEADER = CSV_HEADER + "," + ",".join(TIMING_FIELDS)


class ExtractionError(ValueError):
    """Raised when the console bundle is incomplete or inconsistent."""


def _marker_index(lines: list[str], marker: str) -> int:
    positions = [i for i, line in enumerate(lines) if marker in line]
    if len(positions) != 1:
        raise ExtractionError(f"expected exactly one {marker!r}, found {len(positions)}")
    return positions[0]


def extract_smoke(console_path: Path, out_dir: Path, expected_run_id: str | None = None) -> dict[str, Any]:
    raw = console_path.read_bytes()
    source_sha256 = hashlib.sha256(raw).hexdigest()
    text = raw.decode("utf-8", errors="replace")
    lines = [ANSI_RE.sub("", line.replace("\x00", "")).strip() for line in text.splitlines()]

    summary_lines = [line for line in lines if line.startswith("PROC_TREE_SMOKE run_id=")]
    if len(summary_lines) != 1:
        raise ExtractionError(f"expected one PROC_TREE_SMOKE summary, found {len(summary_lines)}")
    summary_match = re.fullmatch(
        r"PROC_TREE_SMOKE run_id=(\S+) sample_rows=(\d+) processes_started=(\d+) "
        r"memory_errors=(\d+) bad_values=(\d+) start_time_count=(\d+) bad_start_times=(\d+)",
        summary_lines[0],
    )
    if not summary_match:
        raise ExtractionError("malformed smoke summary line")
    (run_id, sample_rows_s, process_started_s, memory_errors_s, bad_values_s,
     start_time_count_s, bad_start_times_s) = summary_match.groups()
    if expected_run_id and run_id != expected_run_id:
        raise ExtractionError(f"run id mismatch: expected {expected_run_id}, got {run_id}")
    sample_rows_expected = int(sample_rows_s)
    process_started_expected = int(process_started_s)
    if (int(memory_errors_s), int(bad_values_s), int(start_time_count_s), int(bad_start_times_s)) != (0, 0, process_started_expected, 0):
        raise ExtractionError("guest smoke summary reports missing memory, invalid values, or zero start ticks")

    csv_marker = _marker_index(lines, "PROC_TREE_SMOKE_MEMORY_CSV_BEGIN")
    events_marker = _marker_index(lines, "PROC_TREE_SMOKE_EVENTS_BEGIN")
    smaps_marker = _marker_index(lines, "PROC_TREE_SMOKE_ROOT_SMAPS_BEGIN")
    pass_marker = _marker_index(lines, "PROC_TREE_SMOKE_PASS")
    if not csv_marker < events_marker < smaps_marker < pass_marker:
        raise ExtractionError("smoke output sections are out of order")

    csv_block = lines[csv_marker + 1:events_marker]
    matching_headers = [line for line in csv_block if line in {CSV_HEADER, EXTENDED_CSV_HEADER}]
    if len(matching_headers) != 1:
        raise ExtractionError("memory CSV header is missing")
    csv_header = matching_headers[0]
    expected_fields = csv_header.split(",")
    if len(expected_fields) != len(set(expected_fields)):
        raise ExtractionError("memory CSV header contains duplicate fields")
    has_timing = csv_header == EXTENDED_CSV_HEADER
    data_lines = [line for line in csv_block if line.startswith(run_id + ",")]
    reader = csv.DictReader(io.StringIO("\n".join([csv_header, *data_lines])))
    rows = list(reader)
    if len(rows) != sample_rows_expected or len(rows) < 16:
        raise ExtractionError(f"CSV row count mismatch: expected {sample_rows_expected}, got {len(rows)}")

    sample_pids: dict[int, set[int]] = {}
    sample_times: dict[int, int] = {}
    sample_timing: dict[int, dict[str, int]] = {}
    sample_timing_state: dict[int, str] = {}
    seen_rows: set[tuple[int, int, str]] = set()
    for row in rows:
        if list(row) != expected_fields:
            raise ExtractionError("CSV columns do not match the sampler schema")
        if row["run_id"] != run_id or row["clock_id"] != "LINUX_CLOCK_MONOTONIC":
            raise ExtractionError("CSV run id or clock domain is inconsistent")
        sample_id, t_ns, pid, ppid = (int(row[name]) for name in ("sample_id", "t_ns", "pid", "ppid"))
        identity = row["process_instance"]
        identity_match = re.fullmatch(r"(\d+)-(\d+)", identity)
        if not identity_match or int(identity_match.group(1)) != pid or int(identity_match.group(2)) == 0:
            raise ExtractionError(f"invalid or zero starttime process identity: {identity}")
        try:
            memory_values = {name: int(row[name]) for name in ("rss_kb", "pss_kb", "uss_kb")}
        except (TypeError, ValueError) as exc:
            raise ExtractionError(f"missing or non-integer RSS/PSS/USS for PID {pid}") from exc
        if any(value < 0 for value in memory_values.values()):
            raise ExtractionError(f"negative RSS/PSS/USS for PID {pid}")
        if has_timing:
            raw_timing = {name: row.get(name) for name in TIMING_FIELDS}
            unavailable = [value == "UNAVAILABLE" for value in raw_timing.values()]
            if any(unavailable):
                if not all(unavailable):
                    raise ExtractionError(f"sample {sample_id} has partially unavailable timing metadata")
                timing_state = "unavailable"
            else:
                timing: dict[str, int] = {}
                for name, raw_value in raw_timing.items():
                    try:
                        value = int(raw_value)
                    except (TypeError, ValueError) as exc:
                        raise ExtractionError(f"invalid timing field {name} for sample {sample_id}") from exc
                    if value < 0:
                        raise ExtractionError(f"negative timing field {name} for sample {sample_id}")
                    timing[name] = value
                if timing["tree_snapshot_total_ns"] <= 0 or timing["tree_smaps_rollup_read_ns"] <= 0 or timing["sample_work_ns"] <= 0:
                    raise ExtractionError(f"non-positive timing duration for sample {sample_id}")
                if timing["tree_snapshot_process_count"] <= 0 or timing["tree_snapshot_resident_pages"] <= 0:
                    raise ExtractionError(f"empty process or resident-page count for sample {sample_id}")
                if sample_id in sample_timing and sample_timing[sample_id] != timing:
                    raise ExtractionError(f"sample {sample_id} has inconsistent timing metadata")
                sample_timing[sample_id] = timing
                timing_state = "available"
            if sample_id in sample_timing_state and sample_timing_state[sample_id] != timing_state:
                raise ExtractionError(f"sample {sample_id} has inconsistent timing availability")
            sample_timing_state[sample_id] = timing_state
        key = (sample_id, pid, identity)
        if key in seen_rows:
            raise ExtractionError(f"duplicate CSV row: {key}")
        seen_rows.add(key)
        sample_pids.setdefault(sample_id, set()).add(pid)
        if sample_id in sample_times and sample_times[sample_id] != t_ns:
            raise ExtractionError(f"sample {sample_id} has mixed timestamps")
        sample_times[sample_id] = t_ns
    sample_ids = sorted(sample_pids)
    if sample_ids != list(range(1, len(sample_ids) + 1)):
        raise ExtractionError("sample ids are not contiguous from 1")
    if any(len(pids) != process_started_expected for pids in sample_pids.values()):
        raise ExtractionError("process count varies or does not match the smoke summary")
    if any(sample_times[a] >= sample_times[b] for a, b in zip(sample_ids, sample_ids[1:])):
        raise ExtractionError("sample timestamps are not strictly increasing")
    if has_timing and len(set(sample_timing_state.values())) != 1:
        raise ExtractionError("timing availability changes between samples")

    event_records: dict[int, dict[str, Any]] = {}
    for line in lines[events_marker + 1:smaps_marker]:
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ExtractionError(f"invalid lifecycle JSON: {exc}") from exc
        if event.get("run_id") != run_id:
            continue
        seq = int(event["seq"])
        if seq in event_records and event_records[seq] != event:
            raise ExtractionError(f"conflicting lifecycle event sequence {seq}")
        event_records[seq] = event
    events = [event_records[key] for key in sorted(event_records)]
    if [event["seq"] for event in events] != [1, 2, 3, 4]:
        raise ExtractionError("lifecycle event sequence is incomplete")
    if [event["event"] for event in events] != [
        "browser_launch_requested", "process_started", "process_started", "memory_sampling_finished"
    ]:
        raise ExtractionError("lifecycle events do not match the smoke sequence")

    root_line_candidates = [line for line in lines if line.startswith("PROC_TREE_SMOKE_BEGIN root_pid=")]
    if len(root_line_candidates) != 1:
        raise ExtractionError("root stat line is missing or duplicated")
    root_match = re.fullmatch(r"PROC_TREE_SMOKE_BEGIN root_pid=(\d+) root_stat=(.*) launch_ns=(\d+)", root_line_candidates[0])
    if not root_match:
        raise ExtractionError("root stat line is malformed")
    root_pid, root_stat, launch_ns = int(root_match.group(1)), root_match.group(2), int(root_match.group(3))
    right_paren = root_stat.rfind(")")
    if right_paren < 0:
        raise ExtractionError("/proc root stat has no closing comm delimiter")
    stat_fields = root_stat[right_paren + 2:].split()
    if len(stat_fields) <= 19:
        raise ExtractionError("/proc root stat is too short to contain field 22")
    root_start_ticks = int(stat_fields[19])
    if root_start_ticks == 0:
        raise ExtractionError("root /proc stat field 22 starttime is zero")
    root_row = next((row for row in rows if int(row["pid"]) == root_pid), None)
    if root_row is None or int(root_row["process_instance"].split("-")[-1]) != root_start_ticks:
        raise ExtractionError("root stat field 22 does not match the sampler process identity")

    status_fields: dict[str, str] = {}
    wanted_status = {"run_id", "result", "samples", "process_instances", "missed", "memory_source", "finished_t_ns"}
    for line in lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in wanted_status and key not in status_fields:
            status_fields[key] = value
    if status_fields.get("run_id") != run_id or status_fields.get("result") != "PASS":
        raise ExtractionError("proc-tree sampler status is absent or not PASS")
    if int(status_fields.get("samples", "-1")) != len(sample_ids):
        raise ExtractionError("sampler status sample count differs from CSV")
    if int(status_fields.get("missed", "-1")) != 0:
        raise ExtractionError("sampler status reports missed samples")
    if status_fields.get("memory_source") != "procfs-tree-smaps_rollup":
        raise ExtractionError("bulk process-tree endpoint was not the active memory source")

    smaps_values: dict[str, int] = {}
    for line in lines[smaps_marker + 1:pass_marker]:
        match = re.match(r"^(Rss|Pss|USS|Shared):\s+(\d+) kB$", line)
        if match:
            smaps_values[match.group(1)] = int(match.group(2))
    if (
        set(smaps_values) != {"Rss", "Pss", "USS", "Shared"}
        or smaps_values.get("Rss", 0) <= 0
        or any(value < 0 for value in smaps_values.values())
    ):
        raise ExtractionError("root smaps_rollup values are incomplete, negative, or have zero RSS")

    if out_dir.exists() and any(out_dir.iterdir()):
        raise ExtractionError(f"refusing to overwrite non-empty output directory: {out_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)
    with (out_dir / "memory-samples.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=expected_fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    (out_dir / "lifecycle-events.jsonl").write_text(
        "".join(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n" for event in events), encoding="utf-8"
    )
    (out_dir / "proc-tree-sampler.status").write_text(
        "".join(f"{key}={status_fields[key]}\n" for key in sorted(wanted_status) if key in status_fields), encoding="utf-8"
    )
    (out_dir / "root-stat.txt").write_text(root_line_candidates[0] + "\n", encoding="utf-8")
    (out_dir / "root-smaps-rollup.txt").write_text(
        "".join(f"{key}: {smaps_values[key]} kB\n" for key in ("Rss", "Pss", "USS", "Shared")), encoding="utf-8"
    )
    summary = {
        "run_id": run_id,
        "source_console_sha256": source_sha256,
        "samples": len(sample_ids),
        "process_instances": process_started_expected,
        "memory_rows": len(rows),
        "missed": 0,
        "memory_source": status_fields["memory_source"],
        "root_pid": root_pid,
        "root_start_ticks": root_start_ticks,
        "launch_ns": launch_ns,
        "root_smaps_rollup_kb": smaps_values,
    }
    timing_available = has_timing and bool(sample_timing_state) and all(
        state == "available" for state in sample_timing_state.values()
    )
    if timing_available:
        timing_statistics: dict[str, dict[str, int | float]] = {}
        for name in TIMING_FIELDS:
            values = sorted(sample[name] for sample in sample_timing.values())
            p95_index = max(0, (95 * len(values) + 99) // 100 - 1)
            timing_statistics[name] = {
                "samples": len(values),
                "min": values[0],
                "median": statistics.median(values),
                "p95": values[p95_index],
                "max": values[-1],
            }
        summary["tree_snapshot_timing"] = {
            "available": True,
            "process_count_semantics": (
                "all-process mapcount snapshot input rows; this is system-wide and does not equal Chromium tree rows"
            ),
            "resident_pages_semantics": (
                "resident user mapping count across all snapshot processes, including repeated shared-frame mappings"
            ),
            "sample_work_ns_scope": (
                "from sample_t_ns through process scan and memory reads, stopping immediately before CSV row emission and flush"
            ),
            "fields": timing_statistics,
        }
    else:
        unavailable_samples = sum(
            state == "unavailable" for state in sample_timing_state.values()
        )
        summary["tree_snapshot_timing"] = {
            "available": False,
            "unavailable_samples": unavailable_samples,
            "reason": (
                "kernel endpoint reported UNAVAILABLE for all optional timing fields"
                if has_timing
                else "CSV does not contain optional kernel timing fields"
            ),
        }
    (out_dir / "extract-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console_log", type=Path, help="unaltered T490 serial console log")
    parser.add_argument("--run-id", help="require this guest smoke run id")
    parser.add_argument("--out-dir", type=Path, required=True, help="new output directory for extracted records")
    args = parser.parse_args(argv)
    try:
        result = extract_smoke(args.console_log, args.out_dir, args.run_id)
    except (OSError, ExtractionError) as exc:
        print(f"PROC_TREE_SMOKE_EXTRACT_FAIL: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
