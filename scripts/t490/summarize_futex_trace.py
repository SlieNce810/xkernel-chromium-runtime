#!/usr/bin/env python3
"""Pair bounded x-kernel Chromium futex call/result records from console.log."""

from __future__ import annotations

import argparse
import collections
import json
import re
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
CALL_RE = re.compile(
    r"CHROMIUM_FUTEX_CALL seq=(?P<seq>\d+) pid=(?P<pid>\d+) "
    r"uaddr=(?P<uaddr>0x[0-9a-fA-F]+) op=(?P<op>0x[0-9a-fA-F]+) "
    r"value=(?P<value>\d+) timeout_or_value2=(?P<timeout>0x[0-9a-fA-F]+) "
    r"uaddr2=(?P<uaddr2>0x[0-9a-fA-F]+) value3=(?P<value3>0x[0-9a-fA-F]+)"
)
RESULT_RE = re.compile(
    r"CHROMIUM_FUTEX_RESULT seq=(?P<seq>\d+) pid=(?P<pid>\d+) "
    r"result=(?P<result>Ok\([^\r\n]*?\)|Err\([^\r\n]*?\))"
)
ERROR_RE = re.compile(r"SANDBOX_SYSCALL_ERROR sysno=futex err=KErrorKind::(?P<kind>[A-Za-z0-9_]+)")

COMMANDS = {
    0: "FUTEX_WAIT",
    1: "FUTEX_WAKE",
    3: "FUTEX_REQUEUE",
    4: "FUTEX_CMP_REQUEUE",
    5: "FUTEX_WAKE_OP",
    6: "FUTEX_LOCK_PI",
    7: "FUTEX_UNLOCK_PI",
    8: "FUTEX_TRYLOCK_PI",
    9: "FUTEX_WAIT_BITSET",
    10: "FUTEX_WAKE_BITSET",
    11: "FUTEX_WAIT_REQUEUE_PI",
    12: "FUTEX_CMP_REQUEUE_PI",
    13: "FUTEX_LOCK_PI2",
}


def parse_trace(text: str, source: str) -> dict[str, object]:
    calls: dict[int, dict[str, object]] = {}
    results: dict[int, dict[str, object]] = {}
    syscall_errors: collections.Counter[str] = collections.Counter()

    for line in ANSI_RE.sub("", text).splitlines():
        call = CALL_RE.search(line)
        if call:
            seq = int(call.group("seq"))
            op = int(call.group("op"), 16)
            command = op & 0x7F
            calls[seq] = {
                "pid": int(call.group("pid")),
                "op": call.group("op"),
                "command": COMMANDS.get(command, f"FUTEX_CMD_{command}"),
                "private": bool(op & 0x80),
                "clock_realtime": bool(op & 0x100),
                "value": int(call.group("value")),
                "timeout_or_value2": call.group("timeout"),
            }
        result = RESULT_RE.search(line)
        if result:
            results[int(result.group("seq"))] = {
                "pid": int(result.group("pid")),
                "result": result.group("result"),
            }
        error = ERROR_RE.search(line)
        if error:
            syscall_errors[error.group("kind")] += 1

    outcome_counts: collections.Counter[str] = collections.Counter()
    command_outcomes: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    paired = 0
    for seq, call in calls.items():
        result = results.get(seq)
        if result is None:
            continue
        paired += 1
        outcome = str(result["result"])
        command = str(call["command"])
        outcome_counts[outcome] += 1
        command_outcomes[command][outcome] += 1

    return {
        "schema": "xk.futex-trace-summary.v1",
        "source": source,
        "call_records": len(calls),
        "result_records": len(results),
        "paired_records": paired,
        "calls_without_result": sorted(set(calls) - set(results)),
        "results_without_call": sorted(set(results) - set(calls)),
        "results": dict(sorted(outcome_counts.items())),
        "by_command": {
            command: dict(sorted(counts.items()))
            for command, counts in sorted(command_outcomes.items())
        },
        "syscall_error_log_counts": dict(sorted(syscall_errors.items())),
        "interpretation": {
            "WouldBlock": "For FUTEX_WAIT, x-kernel's observed value-mismatch path; Linux FUTEX_WAIT returns EAGAIN/EWOULDBLOCK for this race. This is not by itself a blocking failure.",
            "TimedOut": "For a finite FUTEX_WAIT timeout, the expected ETIMEDOUT result. It is not by itself a blocking failure.",
            "OperationNotSupported": "The dispatcher log lacks futex_op and the bounded Chromium trace skips early unsupported-command returns; do not attribute this count to a specific operation or page failure.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("console_log", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    summary = parse_trace(args.console_log.read_text(encoding="utf-8", errors="replace"),
                          args.console_log.as_posix())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")
    print(json.dumps({key: summary[key] for key in (
        "call_records", "result_records", "paired_records", "by_command",
        "syscall_error_log_counts",
    )}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
