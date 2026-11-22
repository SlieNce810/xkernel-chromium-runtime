#!/usr/bin/env python3
"""Recompute the competition's 20-point browser score from immutable gates.

This intentionally accepts only machine-checkable page/gate evidence.  A PID,
an input command returning zero, or a diagnostic single-process round cannot
turn an item green.  The six items are the scoring table used by the final:

* default multiprocess structure: 4
* specified HTML page: 4
* two tabs/windows and switching: 4
* real keyboard echo plus mouse click/navigation: 4
* JavaScript interaction page: 2
* CSS layout page: 2
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PPM_ASSERT = ROOT / "scripts" / "t490" / "ppm_assert.py"
PROCESS_GATE = ROOT / "scripts" / "multiprocess_eventlog.py"


def read_json(path: Path | None) -> tuple[bool, dict[str, Any], str]:
    if path is None:
        return False, {}, "evidence path not supplied"
    if not path.is_file():
        return False, {}, f"missing: {path}"
    try:
        raw = path.read_text(encoding="utf-8")
        # A historical gate writer emitted the two literal characters ``\\n``
        # after the final JSON object.  Accept that harmless serialization
        # suffix while leaving the immutable evidence file untouched.
        if raw.rstrip().endswith(r"\n"):
            raw = raw.rstrip()[:-2].rstrip()
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        return False, {}, f"invalid JSON {path}: {exc}"
    if not isinstance(value, dict):
        return False, {}, f"JSON object required: {path}"
    return True, value, ""


def gate_pass(path: Path | None, expected_mode: str = "default-multiprocess") -> tuple[bool, str]:
    ok, value, reason = read_json(path)
    if not ok:
        return False, reason
    if value.get("mode") not in (None, expected_mode):
        return False, f"mode={value.get('mode')!r}, expected {expected_mode!r}"
    if value.get("pass") is not True:
        return False, "gate pass is not true"
    return True, "gate pass=true"


def ppm_pass(path: Path | None, profile: str) -> tuple[bool, str]:
    if path is None:
        return False, "evidence path not supplied"
    if not path.is_file():
        return False, f"missing: {path}"
    proc = subprocess.run(
        [sys.executable, str(PPM_ASSERT), str(path), "--profile", profile,
         "--strict", "--quiet"],
        text=True,
        capture_output=True,
        check=False,
    )
    detail = (proc.stdout.strip() or proc.stderr.strip()).splitlines()
    return proc.returncode == 0, detail[-1] if detail else f"ppm_assert rc={proc.returncode}"


def process_pass(summary: Path | None, events: Path | None) -> tuple[bool, str]:
    if summary is not None:
        return gate_pass(summary)
    if events is None:
        return False, "process summary or event ledger not supplied"
    if not events.is_file():
        return False, f"missing: {events}"
    with tempfile.TemporaryDirectory(prefix="xk-score20-") as temp:
        out = Path(temp) / "process-summary.json"
        proc = subprocess.run(
            [sys.executable, str(PROCESS_GATE), str(events),
             "--criterion", "process-structure", "--strict", "--summary", str(out)],
            text=True,
            capture_output=True,
            check=False,
        )
        if proc.returncode != 0:
            detail = (proc.stdout.strip() or proc.stderr.strip()).splitlines()
            return False, detail[-1] if detail else f"process gate rc={proc.returncode}"
        return True, "multiprocess event ledger passed"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--index", type=Path, help="official-index PPM")
    ap.add_argument("--layout", type=Path, help="official-layout PPM")
    ap.add_argument("--tabs-gate", type=Path)
    ap.add_argument("--interaction-gate", type=Path,
                    help="combined real keyboard + mouse gate")
    ap.add_argument("--javascript-gate", type=Path)
    ap.add_argument("--process-summary", type=Path)
    ap.add_argument("--events", type=Path, help="raw MP_EVENT JSONL")
    ap.add_argument("--out", type=Path, help="write the JSON result")
    ap.add_argument("--strict", action="store_true",
                    help="exit nonzero unless all 20 points pass")
    args = ap.parse_args()

    rows: dict[str, dict[str, Any]] = {}
    checks = [
        ("process-structure", 4,
         lambda: process_pass(args.process_summary, args.events)),
        ("specified-html", 4,
         lambda: ppm_pass(args.index, "official-index")),
        ("tabs-switching", 4,
         lambda: gate_pass(args.tabs_gate)),
        ("real-input", 4,
         lambda: gate_pass(args.interaction_gate)),
        ("javascript", 2,
         lambda: gate_pass(args.javascript_gate)),
        ("css-layout", 2,
         lambda: ppm_pass(args.layout, "official-layout")),
    ]
    points = 0
    for name, weight, check in checks:
        passed, reason = check()
        if passed:
            points += weight
        rows[name] = {"points": weight, "pass": passed, "reason": reason}

    payload = {
        "schema": "xkernel.competition-score20.v1",
        "score": points,
        "max_score": 20,
        "items": rows,
    }
    encoded = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if (not args.strict or points == 20) else 1


if __name__ == "__main__":
    raise SystemExit(main())
