#!/usr/bin/env python3
"""Normalize only empty family rows caused by MP_FAMILY_COUNT markers.

An actual MP_FAMILY snapshot with missing Browser/Zygote/Renderer roles is
evidence of an incomplete process-family observation. It invalidates earlier
snapshots for later liveness checks and must never be replaced with stale PIDs.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA = "xkernel.stability.v1"
REQUIRED_FAMILY_ROLES = {"browser_child", "zygote_child"}
MAX_FAMILY_AGE_NS = 35_000_000_000


def normalize_rows(
    rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    errors: list[str] = []
    repaired: list[dict[str, Any]] = []
    latest_family: dict[str, Any] | None = None
    latest_family_t_ns = -1
    latest_family_event_id = ""

    for line_no, original in enumerate(rows, 1):
        row = copy.deepcopy(original)
        if row.get("schema") != SCHEMA:
            errors.append(f"line {line_no}: wrong schema")
        if row.get("event") == "guest_process_snapshot":
            family = row.get("roles")
            members = row.get("members")
            raw_snapshot = row.get("raw")
            try:
                family_t_ns = int(row.get("t_ns", -1))
            except (TypeError, ValueError):
                family_t_ns = -1
            is_count_marker = isinstance(raw_snapshot, str) and "MP_FAMILY_COUNT=" in raw_snapshot
            if is_count_marker:
                # This legacy marker carries a process count, not a family tree.
                pass
            elif (
                isinstance(family, list)
                and REQUIRED_FAMILY_ROLES.issubset(set(family))
                and isinstance(members, list)
                and members
                and family_t_ns >= 0
            ):
                latest_family = {
                    "members": members,
                    "roles": family,
                    "n": int(row.get("n", len(members))),
                }
                latest_family_t_ns = family_t_ns
                latest_family_event_id = str(row.get("event_id", ""))
            else:
                # A real but incomplete snapshot supersedes any older complete
                # one. Never carry old renderer PIDs across this observation.
                latest_family = None
                latest_family_t_ns = family_t_ns
                latest_family_event_id = str(row.get("event_id", ""))

        if row.get("event") == "host_liveness":
            family = row.get("guest_family")
            roles = family.get("roles", []) if isinstance(family, dict) else []
            family_age = row.get("guest_family_age_s")
            try:
                current_age_s = float(family_age)
            except (TypeError, ValueError):
                current_age_s = float("inf")
            current_is_usable = (
                isinstance(roles, list)
                and REQUIRED_FAMILY_ROLES.issubset(set(roles))
                and current_age_s <= 35.0
            )
            if not current_is_usable:
                empty_family = (
                    isinstance(family, dict)
                    and family.get("roles") == []
                    and family.get("members") == []
                    and family.get("n") == 0
                )
                if not empty_family:
                    errors.append(
                        f"line {line_no}: liveness contains an incomplete non-empty family snapshot"
                    )
                    normalized.append(row)
                    continue
                try:
                    host_t_ns = int(row.get("t_ns", -1))
                except (TypeError, ValueError):
                    host_t_ns = -1
                age_ns = host_t_ns - latest_family_t_ns
                if (
                    latest_family is None
                    or host_t_ns < 0
                    or age_ns < 0
                    or age_ns > MAX_FAMILY_AGE_NS
                ):
                    errors.append(
                        f"line {line_no}: no fresh non-empty Browser/Zygote/Renderer family snapshot"
                    )
                else:
                    row["guest_family"] = copy.deepcopy(latest_family)
                    row["guest_family_age_s"] = age_ns / 1_000_000_000
                    row["family_normalized"] = True
                    row["family_normalized_from_event_id"] = latest_family_event_id
                    repaired.append(
                        {
                            "line": line_no,
                            "event_id": row.get("event_id", ""),
                            "source_event_id": latest_family_event_id,
                            "age_s": row["guest_family_age_s"],
                        }
                    )
        normalized.append(row)

    summary = {
        "schema": "xkernel.stability-event-normalization.v1",
        "result": "PASS" if not errors else "FAIL",
        "input_event_count": len(rows),
        "output_event_count": len(normalized),
        "repaired_liveness_count": len(repaired),
        "repaired_liveness": repaired,
        "errors": errors,
    }
    return normalized, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", type=Path, help="raw xkernel.stability.v1 JSONL")
    parser.add_argument("output", type=Path, help="normalized JSONL output")
    parser.add_argument("--summary", type=Path, help="normalization summary JSON")
    args = parser.parse_args()

    if not args.events.is_file():
        print(f"[FAIL] events file missing: {args.events}", file=sys.stderr)
        return 2
    rows: list[dict[str, Any]] = []
    errors: list[str] = []
    for line_no, raw in enumerate(args.events.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            errors.append(f"line {line_no}: invalid JSON: {exc.msg}")
            continue
        if not isinstance(value, dict):
            errors.append(f"line {line_no}: event must be an object")
            continue
        rows.append(value)

    normalized, summary = normalize_rows(rows)
    summary["parse_errors"] = errors
    if errors:
        summary["result"] = "FAIL"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as stream:
        for row in normalized:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
