#!/usr/bin/env python3
"""Normalize compact process observations from a QEMU guest console log.

Some early guest console writes truncate the first MP_EVENT record after its
PID and PPID. The observer also writes a separate MP_PROCESS_OBSERVED line for
the same process. This tool joins only those exact role/PID/PPID observations
and fills fields that are constant in the observer schema. The console and
the raw MP_EVENT extraction remain unchanged; reconstructed records are
marked in the sidecar summary and in each normalized event.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PARTIAL_EVENT = re.compile(
    r'^\{"timestamp_monotonic":(?P<timestamp>(?:\d+(?:\.\d*)?|\.\d+)),'
    r'"process_role":"(?P<role>[^"]+)","pid":(?P<pid>\d+),'
    r'"ppid":(?P<ppid>\d+)'
)
PROCESS_OBSERVATION = re.compile(
    r"MP_PROCESS_OBSERVED\s+role=(?P<role>[a-z]+)\s+"
    r"event=(?P<event>[a-z-]+)\s+pid=(?P<pid>\d+)\s+ppid=(?P<ppid>\d+)"
)
PROCESS_EVENTS = {
    "browser": {"browser-start"},
    "zygote": {"zygote-start", "zygote-observed"},
    "renderer": {"renderer-exec", "renderer-observed"},
}
PROCESS_SOURCES = {
    "browser": "guest-launcher",
    "zygote": "guest-ps-snapshot",
    "renderer": "guest-ps-snapshot",
}


def _clean_lines(text: str) -> list[str]:
    # QEMU's serial path can serialize the first character of an event marker
    # as the final byte of a CSI sequence: ``ESC[MP_EVENT``. Preserve that
    # marker before removing terminal control sequences or browser-start is
    # silently dropped as a delete-line command.
    text = text.replace("\x1b[MP_EVENT ", "MP_EVENT ")
    cleaned = ANSI_ESCAPE.sub("", text)
    return [line for line in cleaned.splitlines() if line]


def _observations(lines: list[str]) -> dict[tuple[str, int, int], set[str]]:
    found: dict[tuple[str, int, int], set[str]] = {}
    for line in lines:
        marker = line.find("MP_PROCESS_OBSERVED ")
        if marker < 0:
            continue
        match = PROCESS_OBSERVATION.search(line[marker:])
        if match is None:
            continue
        key = (
            match.group("role"),
            int(match.group("pid")),
            int(match.group("ppid")),
        )
        found.setdefault(key, set()).add(match.group("event"))
    return found


def _reconstruct_partial(
    candidate: str,
    line_number: int,
    observations: dict[tuple[str, int, int], set[str]],
) -> tuple[dict[str, Any] | None, str | None]:
    match = PARTIAL_EVENT.match(candidate)
    if match is None:
        return None, f"line {line_number}: truncated MP_EVENT has no usable timestamp/role/PID/PPID prefix"

    role = match.group("role")
    pid = int(match.group("pid"))
    ppid = int(match.group("ppid"))
    if role not in PROCESS_EVENTS:
        return None, f"line {line_number}: truncated non-process MP_EVENT cannot be reconstructed"

    event_names = observations.get((role, pid, ppid), set())
    candidates = event_names & PROCESS_EVENTS[role]
    if len(candidates) != 1:
        return None, (
            f"line {line_number}: expected one matching MP_PROCESS_OBSERVED "
            f"for role={role} pid={pid} ppid={ppid}; found {sorted(candidates)}"
        )

    event: dict[str, Any] = {
        "timestamp_monotonic": float(match.group("timestamp")),
        "process_role": role,
        "pid": pid,
        "ppid": ppid,
        "navigation_id": 0,
        "frame_tree_node_id": 0,
        "document_id": "",
        "mojo_endpoint_or_pipe_id": "",
        "shared_object_id_or_file_object_id": "",
        "event": next(iter(candidates)),
        "status": "observed",
        "error": "",
        "observation_source": PROCESS_SOURCES[role],
        "console_reconstructed": True,
    }
    return event, None


def normalize_console_text(text: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    lines = _clean_lines(text)
    observations = _observations(lines)
    events: list[dict[str, Any]] = []
    errors: list[str] = []
    reconstructed: list[dict[str, Any]] = []
    ignored = 0

    for line_number, line in enumerate(lines, 1):
        marker = line.find("MP_EVENT ")
        if marker < 0:
            continue
        candidate = line[marker + len("MP_EVENT ") :].strip()
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            value, error = _reconstruct_partial(candidate, line_number, observations)
            if error is not None:
                errors.append(error)
                continue
            assert value is not None
            reconstructed.append(
                {
                    "line": line_number,
                    "process_role": value["process_role"],
                    "pid": value["pid"],
                    "ppid": value["ppid"],
                    "event": value["event"],
                }
            )

        if not isinstance(value, dict):
            errors.append(f"line {line_number}: MP_EVENT must be a JSON object")
            continue
        role = value.get("process_role")
        name = value.get("event")
        if role not in PROCESS_EVENTS or name not in PROCESS_EVENTS[role]:
            ignored += 1
            continue
        events.append(value)

    summary = {
        "schema": "xkernel.process-event-normalization.v1",
        "result": "PASS" if not errors else "FAIL",
        "mp_event_lines": sum(1 for line in lines if "MP_EVENT " in line),
        "normalized_process_events": len(events),
        "reconstructed_count": len(reconstructed),
        "reconstructed_events": reconstructed,
        "ignored_non_process_events": ignored,
        "errors": errors,
    }
    return events, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console_log", type=Path)
    parser.add_argument("output_jsonl", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    if not args.console_log.is_file():
        print(f"[FAIL] console log missing: {args.console_log}", file=sys.stderr)
        return 2

    text = args.console_log.read_text(encoding="utf-8", errors="replace")
    events, summary = normalize_console_text(text)
    args.output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with args.output_jsonl.open("w", encoding="utf-8", newline="\n") as stream:
        for event in events:
            stream.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if not summary["errors"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
