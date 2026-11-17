#!/usr/bin/env python3
"""Validate and summarize browser multi-process event ledgers.

The Chromium-side instrumentation and the guest process observer write one JSON
object per line. This dependency-free tool has two separate criteria:
``full-render`` validates the renderer-to-Wayland page chain, while
``process-structure`` validates that Browser, zygote, and renderer roles were
observed as distinct processes with the expected direct PPID ancestry. The
latter is only the 4-point process observability criterion; it does not mean a
page rendered or sandbox passed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


REQUIRED_FIELDS = {
    "timestamp_monotonic",
    "process_role",
    "pid",
    "ppid",
    "navigation_id",
    "frame_tree_node_id",
    "document_id",
    "mojo_endpoint_or_pipe_id",
    "shared_object_id_or_file_object_id",
    "event",
    "status",
    "error",
}

REQUIRED_CHAIN = (
    "browser-start",
    "zygote-start",
    "renderer-exec",
    "sandbox-init",
    "navigation-start",
    "response-start",
    "response-complete",
    "document-commit",
    "frame-created",
    "wayland-configure",
    "wayland-ack-configure",
    "wayland-buffer-attach",
    "wayland-commit",
)

PROCESS_STRUCTURE_EVENTS = {
    "browser": ("browser-start",),
    "zygote": ("zygote-start", "zygote-observed"),
    "renderer": ("renderer-exec", "renderer-observed"),
}

PROCESS_STRUCTURE_FORBIDDEN_FLAGS = (
    "--single-process",
    "--no-zygote",
)

FORBIDDEN_DIAGNOSTIC_FLAGS = (
    "--single-process",
    "--no-zygote",
    "--no-sandbox",
    "--renderer-cmd-prefix",
    "--remote-debugging-port",
)


def _read_jsonl(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    events: list[dict[str, Any]] = []
    errors: list[str] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # Chromium writes the event object through LOG(INFO), so guest console
        # lines normally contain a prefix such as ``[INFO:... ] MP_EVENT``.
        # Keep accepting raw JSONL for unit probes, while extracting the
        # marked object from a normal Chromium log line.
        candidate = line
        marker = "MP_EVENT "
        marker_index = line.find(marker)
        if marker_index >= 0:
            candidate = line[marker_index + len(marker) :].strip()
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError as exc:
            errors.append(f"line {lineno}: invalid JSON ({exc.msg})")
            continue
        if not isinstance(value, dict):
            errors.append(f"line {lineno}: event must be a JSON object")
            continue
        value["_line"] = lineno
        events.append(value)
    return events, errors


def _validate_events(events: Iterable[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    for event in events:
        line = event.get("_line", "?")
        missing = sorted(REQUIRED_FIELDS - event.keys())
        if missing:
            errors.append(f"line {line}: missing fields: {', '.join(missing)}")
        if not isinstance(event.get("pid"), int) or event.get("pid", 0) <= 0:
            errors.append(f"line {line}: pid must be a positive integer")
        if not isinstance(event.get("ppid"), int) or event.get("ppid", 0) < 0:
            errors.append(f"line {line}: ppid must be a non-negative integer")
        if not isinstance(event.get("timestamp_monotonic"), (int, float)):
            errors.append(f"line {line}: timestamp_monotonic must be numeric")
        for field in ("navigation_id", "frame_tree_node_id"):
            if not isinstance(event.get(field), int) or event.get(field, -1) < 0:
                errors.append(f"line {line}: {field} must be a non-negative integer")
        for field in ("process_role", "event", "status"):
            if not isinstance(event.get(field), str) or not event.get(field):
                errors.append(f"line {line}: {field} must be a non-empty string")
        for field in (
            "document_id",
            "mojo_endpoint_or_pipe_id",
            "shared_object_id_or_file_object_id",
            "error",
        ):
            if not isinstance(event.get(field), str):
                errors.append(f"line {line}: {field} must be a string")
    return errors


def _check_command(path: Path) -> list[str]:
    if not path.exists():
        return [f"command file does not exist: {path}"]
    text = path.read_text(encoding="utf-8", errors="replace")
    found = [flag for flag in FORBIDDEN_DIAGNOSTIC_FLAGS if flag in text]
    return [f"forbidden diagnostic flag in score command: {flag}" for flag in found]


def _check_process_structure_command(path: Path) -> list[str]:
    if not path.exists():
        return [f"command file does not exist: {path}"]
    text = path.read_text(encoding="utf-8", errors="replace")
    found = [flag for flag in PROCESS_STRUCTURE_FORBIDDEN_FLAGS if flag in text]
    return [f"forbidden process-structure flag in score command: {flag}" for flag in found]


def _is_success(event: dict[str, Any]) -> bool:
    return str(event.get("status", "")).lower() not in {
        "error",
        "fail",
        "failed",
        "denied",
        "crash",
        "timeout",
    }


def _matches_identity(
    event: dict[str, Any],
    *,
    navigation_id: int | None,
    document_id: str | None,
) -> bool:
    """Match an event to one navigation without requiring optional IDs.

    The first diagnostic patch intentionally emits zero/empty IDs at process
    startup and for compositor events that do not carry a NavigationRequest.
    Those events still belong to the single run, so zero/empty values are
    treated as wildcards.  Once a non-zero/non-empty identity is present, a
    conflicting value is never accepted.
    """

    if navigation_id is not None:
        event_navigation = event.get("navigation_id")
        if event_navigation not in (0, navigation_id):
            return False
    if document_id:
        event_document = event.get("document_id", "")
        if event_document not in ("", document_id):
            return False
    return True


def _renderer_chains(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return chain checks keyed by renderer PID and navigation identity.

    A global event count is insufficient: an unrelated renderer can supply a
    commit while another renderer supplied the sandbox event.  This check
    keeps renderer lifecycle events on one PID and uses navigation/document
    IDs whenever the instrumented event has them.
    """

    success_events = [event for event in events if _is_success(event)]
    renderer_pids = sorted(
        {
            int(event["pid"])
            for event in success_events
            if event.get("process_role") == "renderer"
            and event.get("event") == "renderer-exec"
            and isinstance(event.get("pid"), int)
        }
    )
    chains: list[dict[str, Any]] = []
    for pid in renderer_pids:
        renderer_events = [event for event in success_events if event.get("pid") == pid]
        sandbox_events = [event for event in renderer_events if event.get("event") == "sandbox-init"]
        if not sandbox_events:
            chains.append({"renderer_pid": pid, "result": "FAIL", "missing": ["sandbox-init"]})
            continue

        navigation_ids = sorted(
            {
                int(event["navigation_id"])
                for event in renderer_events
                if isinstance(event.get("navigation_id"), int)
                and event.get("navigation_id", 0) > 0
            }
        )
        if not navigation_ids:
            navigation_ids = [0]

        for navigation_id in navigation_ids:
            renderer_identity = next(
                (
                    event
                    for event in renderer_events
                    if event.get("event") in {"document-loader", "document-commit"}
                    and event.get("document_id")
                    and _matches_identity(event, navigation_id=navigation_id, document_id=None)
                ),
                None,
            )
            document_id = str(renderer_identity.get("document_id", "")) if renderer_identity else ""
            positions: dict[str, int] = {}
            missing: list[str] = []
            for name in REQUIRED_CHAIN:
                candidates = [
                    (index, event)
                    for index, event in enumerate(success_events)
                    if event.get("event") == name
                    and _matches_identity(
                        event,
                        navigation_id=navigation_id,
                        document_id=document_id,
                    )
                    and (
                        name not in {"renderer-exec", "sandbox-init", "document-loader", "document-commit"}
                        or event.get("pid") == pid
                    )
                ]
                if not candidates:
                    missing.append(name)
                else:
                    positions[name] = candidates[0][0]

            order_errors = [
                f"{left} must precede {right}"
                for left, right in zip(REQUIRED_CHAIN, REQUIRED_CHAIN[1:])
                if left in positions and right in positions and positions[left] >= positions[right]
            ]
            chain_result = "PASS" if not missing and not order_errors else "FAIL"
            chains.append(
                {
                    "renderer_pid": pid,
                    "navigation_id": navigation_id,
                    "document_id": document_id,
                    "result": chain_result,
                    "missing": missing,
                    "order_errors": order_errors,
                    "positions": positions,
                }
            )
    return chains


def summarize(events: list[dict[str, Any]], parse_errors: list[str]) -> dict[str, Any]:
    valid = [event for event in events if not (set(REQUIRED_FIELDS) - event.keys())]
    successful = [
        event for event in valid
        if str(event.get("status", "")).lower() not in {"error", "fail", "failed", "denied", "crash", "timeout"}
    ]
    roles = Counter(event.get("process_role") for event in valid)
    event_counts = Counter(event.get("event") for event in valid)
    by_pid: dict[str, set[str]] = defaultdict(set)
    for event in valid:
        by_pid[str(event["pid"])].add(event.get("event", ""))

    successful_counts = Counter(event.get("event") for event in successful)
    chain_missing = [name for name in REQUIRED_CHAIN if successful_counts[name] == 0]
    chain_positions = {
        name: min(
            (index for index, event in enumerate(events) if event.get("event") == name),
            default=-1,
        )
        for name in REQUIRED_CHAIN
    }
    out_of_order = [
        f"{left} must precede {right}"
        for left, right in zip(REQUIRED_CHAIN, REQUIRED_CHAIN[1:])
        if chain_positions[left] >= 0 and chain_positions[right] >= 0 and chain_positions[left] >= chain_positions[right]
    ]
    if out_of_order:
        chain_missing.extend(out_of_order)
    renderer_chains = _renderer_chains(events)
    renderer_pids = sorted({chain["renderer_pid"] for chain in renderer_chains})
    correlated_pass = any(chain.get("result") == "PASS" for chain in renderer_chains)
    result = "PASS" if not parse_errors and not chain_missing and correlated_pass else "FAIL"
    return {
        "schema": "xkernel.chromium.multiprocess-events.v1",
        "result": result,
        "event_count": len(events),
        "valid_event_count": len(valid),
        "parse_errors": parse_errors,
        "roles": dict(sorted(roles.items())),
        "event_counts": dict(sorted(event_counts.items())),
        "renderer_sandbox_pids": renderer_pids,
        "renderer_chains": renderer_chains,
        "required_chain_missing": chain_missing,
        "successful_event_count": len(successful),
    }


def summarize_process_structure(
    events: list[dict[str, Any]], parse_errors: list[str]
) -> dict[str, Any]:
    """Score the observable browser → zygote → renderer process structure.

    This criterion intentionally does not depend on sandbox initialization,
    document commit, compositor output, or page pixels. Those are checked by
    the full-render gate and the separate browser-function evidence. It does
    require the direct PPID chain so unrelated or short-lived probe processes
    cannot stand in for a renderer.
    """

    valid = [event for event in events if not (set(REQUIRED_FIELDS) - event.keys())]
    successful = [event for event in valid if _is_success(event)]
    selected = {
        role: [
            event
            for event in successful
            if event.get("process_role") == role and event.get("event") in event_names
            and (
                event.get("event") not in {"zygote-observed", "renderer-observed"}
                or event.get("observation_source") == "guest-ps-snapshot"
            )
        ]
        for role, event_names in PROCESS_STRUCTURE_EVENTS.items()
    }
    untrusted_observations = [
        {
            "process_role": event.get("process_role"),
            "pid": event.get("pid"),
            "event": event.get("event"),
            "observation_source": event.get("observation_source", ""),
            "reason": "guest process observation is missing the trusted source tag",
        }
        for event in valid
        if event.get("event") in {"zygote-observed", "renderer-observed"}
        and event.get("observation_source") != "guest-ps-snapshot"
    ]
    missing = [
        "|".join(event_names)
        for role, event_names in PROCESS_STRUCTURE_EVENTS.items()
        if not selected[role]
    ]

    process_tree: dict[str, int] | None = None
    parent_links_verified = False
    order_errors: list[str] = []
    parent_link_errors: list[str] = []
    if not missing:
        for browser in selected["browser"]:
            for zygote in selected["zygote"]:
                for renderer in selected["renderer"]:
                    if len({browser.get("pid"), zygote.get("pid"), renderer.get("pid")}) != 3:
                        continue
                    if zygote.get("ppid") != browser.get("pid"):
                        parent_link_errors.append(
                            f"zygote pid={zygote.get('pid')} ppid={zygote.get('ppid')} is not browser pid={browser.get('pid')}"
                        )
                        continue
                    if renderer.get("ppid") != zygote.get("pid"):
                        parent_link_errors.append(
                            f"renderer pid={renderer.get('pid')} ppid={renderer.get('ppid')} is not zygote pid={zygote.get('pid')}"
                        )
                        continue
                    times = (
                        browser.get("timestamp_monotonic"),
                        zygote.get("timestamp_monotonic"),
                        renderer.get("timestamp_monotonic"),
                    )
                    if times[0] < times[1] < times[2]:
                        process_tree = {
                            "browser_pid": int(browser["pid"]),
                            "browser_ppid": int(browser["ppid"]),
                            "zygote_pid": int(zygote["pid"]),
                            "zygote_ppid": int(zygote["ppid"]),
                            "renderer_pid": int(renderer["pid"]),
                            "renderer_ppid": int(renderer["ppid"]),
                        }
                        parent_links_verified = (
                            zygote.get("ppid") == browser.get("pid")
                            and renderer.get("ppid") == zygote.get("pid")
                        )
                        break
                    order_errors.append("browser-start < zygote-start < renderer-exec")
                if process_tree:
                    break
            if process_tree:
                break

    ipc_events = [
        event
        for event in successful
        if str(event.get("event", "")).startswith(("mojo-", "datapipe-"))
        or str(event.get("event", "")).startswith("datapipe_")
    ]
    result = (
        "PASS"
        if not parse_errors and not missing and process_tree is not None
        else "FAIL"
    )
    alternate_parent_link_mismatches = parent_link_errors if process_tree is not None else []
    reported_parent_link_errors = [] if process_tree is not None else parent_link_errors
    return {
        "schema": "xkernel.chromium.multiprocess-events.v1",
        "criterion": "process-structure",
        "result": result,
        "score_points": 4 if result == "PASS" else 0,
        "event_count": len(events),
        "valid_event_count": len(valid),
        "parse_errors": parse_errors,
        "required_events_missing": missing,
        "untrusted_observation_count": len(untrusted_observations),
        "untrusted_observations": untrusted_observations,
        "process_tree": process_tree,
        "parent_links_verified": parent_links_verified,
        "parent_link_errors": reported_parent_link_errors,
        "alternate_parent_link_mismatches": alternate_parent_link_mismatches,
        "order_errors": order_errors,
        "ipc_event_count": len(ipc_events),
        "ipc_process_pids": sorted({int(event["pid"]) for event in ipc_events}),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", type=Path, help="Chromium JSONL event ledger")
    parser.add_argument("--command", type=Path, help="score command/evidence file")
    parser.add_argument("--summary", type=Path, help="write machine-readable summary JSON")
    parser.add_argument(
        "--criterion",
        choices=("full-render", "process-structure"),
        default="full-render",
        help=(
            "validate the 4-point observable process tree independently, or "
            "the full renderer-to-Wayland rendering chain (default)"
        ),
    )
    parser.add_argument("--strict", action="store_true", help="fail when the selected criterion does not pass")
    args = parser.parse_args()

    if not args.events.exists():
        print(f"[FAIL] event ledger missing: {args.events}", file=sys.stderr)
        return 2
    events, errors = _read_jsonl(args.events)
    errors.extend(_validate_events(events))
    if args.command:
        if args.criterion == "process-structure":
            errors.extend(_check_process_structure_command(args.command))
        else:
            errors.extend(_check_command(args.command))
    if args.criterion == "process-structure":
        summary = summarize_process_structure(events, errors)
    else:
        summary = summarize(events, errors)
        summary["criterion"] = "full-render"
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.strict and summary["result"] != "PASS":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
