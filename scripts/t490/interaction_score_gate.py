#!/usr/bin/env python3
"""Recompute real keyboard, mouse, JavaScript, and navigation evidence.

The keyboard echo is verified by a localized before/after pixel diff, the
mouse counter by a second localized diff after scrolling, JavaScript by the
official interaction self-check, and navigation by the official layout page.
The JSONL input ledger must also show the corresponding real key and pointer
actions.  A successful readiness screenshot alone never passes the gate.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PPM_ASSERT = ROOT / "scripts" / "t490" / "ppm_assert.py"


def run_ppm(*args: str) -> tuple[bool, str, dict[str, Any]]:
    proc = subprocess.run([sys.executable, str(PPM_ASSERT), *args],
                          text=True, capture_output=True, check=False)
    detail = (proc.stdout.strip() or proc.stderr.strip()).splitlines()
    report: dict[str, Any] = {}
    match = re.search(r"\{\"file\".*\}", proc.stdout)
    return proc.returncode == 0, detail[-1] if detail else f"rc={proc.returncode}", report


def layout_verdict(path: Path) -> tuple[bool, str]:
    """Check the rendered CSS page's own 6/6 verdict in a scrolled viewport."""
    if not path.is_file():
        return False, f"missing: {path}"
    report = path.with_suffix(path.suffix + ".layout-assert.json")
    proc = subprocess.run(
        [sys.executable, str(PPM_ASSERT), str(path), "--profile", "official-layout",
         "--json", str(report), "--quiet"],
        text=True, capture_output=True, check=False,
    )
    try:
        data = json.loads(report.read_text(encoding="utf-8"))
        check = next(row for row in data.get("checks", [])
                     if row.get("check") == "layout_verdict_pass")
    except (OSError, json.JSONDecodeError, StopIteration) as exc:
        return False, f"layout verdict assertion unavailable: {exc}"
    return bool(check.get("pass")), check.get("detail", f"ppm_assert rc={proc.returncode}")


def pixel_diff(after: Path, before: Path, roi: str, minimum: int) -> tuple[bool, str]:
    if not after.is_file() or not before.is_file():
        return False, f"missing diff input: {before} / {after}"
    proc = subprocess.run(
        [sys.executable, str(PPM_ASSERT), str(after), "--diff", str(before),
         "--roi", roi, "--min-changed", str(minimum),
         "--max-bbox-coverage", "0.60", "--quiet"],
        text=True, capture_output=True, check=False,
    )
    detail = (proc.stdout.strip() or proc.stderr.strip()).splitlines()
    return proc.returncode == 0, detail[-1] if detail else f"pixel diff rc={proc.returncode}"


def input_actions(path: Path) -> tuple[bool, str, dict[str, int]]:
    counts = {"real_key_actions": 0, "hmp_pointer_clicks": 0,
              "hmp_pointer_moves": 0}
    if not path.is_file():
        return False, f"missing input event ledger: {path}", counts
    try:
        for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                return False, f"invalid JSONL line {line_no}: {exc}", counts
            if row.get("kind") != "action":
                continue
            value = row.get("value", {})
            op, transport = value.get("op"), value.get("transport")
            if op in {"key", "key-chord"} and transport in {
                    "send-key", "send-key-chord", "qmp", "hmp"}:
                counts["real_key_actions"] += 1
            if op == "click" and transport == "hmp":
                counts["hmp_pointer_clicks"] += 1
            if op == "relative" and transport == "hmp":
                counts["hmp_pointer_moves"] += 1
    except OSError as exc:
        return False, str(exc), counts
    ok = (counts["real_key_actions"] >= 10
          and counts["hmp_pointer_clicks"] >= 4
          and counts["hmp_pointer_moves"] >= 4)
    return ok, ("real input actions recorded" if ok else
                "insufficient real key/HMP pointer actions"), counts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("evidence", type=Path,
                    help="interaction-shots directory plus interaction-events.jsonl")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--ready-rc", type=int, default=0)
    ap.add_argument("--driver-rc", type=int, default=0)
    ap.add_argument("--round-rc", type=int, default=0)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    root = args.evidence
    if (root / "interaction-shots").is_dir():
        shots = root / "interaction-shots"
    elif (root / "shots").is_dir():
        shots = root / "shots"
    else:
        shots = root
    ledger = root / "interaction-events.jsonl"

    js_path = shots / "after-selftest.ppm"
    js_ok, js_detail, _ = run_ppm(str(js_path), "--profile", "official-interaction",
                                  "--expect-input", "--strict", "--quiet")
    keyboard_ok, keyboard_detail = pixel_diff(
        shots / "after-keyboard-echo.ppm", shots / "before-keyboard-echo.ppm",
        "220,670,1045,765", 200)
    mouse_ok, mouse_detail = pixel_diff(
        shots / "after-mouse-click.ppm", shots / "after-scroll.ppm",
        "180,610,1100,755", 20)
    navigation_path = shots / "after-mouse-navigation.ppm"
    navigation_ok, navigation_detail = layout_verdict(navigation_path)
    actions_ok, actions_detail, action_counts = input_actions(ledger)

    checks = {
        "javascript_selftest": {"pass": js_ok, "reason": js_detail},
        "keyboard_echo_diff": {"pass": keyboard_ok, "reason": keyboard_detail},
        "mouse_counter_diff": {"pass": mouse_ok, "reason": mouse_detail},
        "mouse_navigation": {"pass": navigation_ok, "reason": navigation_detail},
        "real_input_actions": {"pass": actions_ok, "reason": actions_detail,
                                **action_counts},
    }
    payload = {
        "schema": "xkernel.interaction-score-gate.v2",
        "mode": "default-multiprocess",
        "sandbox_mode": "diagnostic-no-sandbox",
        "input_transport": "QMP send-key + HMP virtio-mouse",
        "ready_rc": args.ready_rc,
        "driver_rc": args.driver_rc,
        "round_rc": args.round_rc,
        "javascript_pass": js_ok,
        "keyboard_pass": keyboard_ok and actions_ok,
        "mouse_pass": mouse_ok and navigation_ok and actions_ok,
        "checks": checks,
        "pass": args.ready_rc == 0 and args.driver_rc == 0 and args.round_rc == 0
            and keyboard_ok and mouse_ok and navigation_ok and actions_ok,
    }
    encoded = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if (not args.strict or payload["pass"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
