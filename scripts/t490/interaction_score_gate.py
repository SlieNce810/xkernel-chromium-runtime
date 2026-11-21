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
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
# The runner is copied to an isolated T490 staging directory before a guest
# starts.  In that layout ``parents[2]`` is ``/home/mo/xk6/tmp`` rather than a
# repository checkout, so resolving only from ROOT silently made every score
# check fail with a missing ppm_assert.py.  Prefer an explicit override and
# then the staged helper beside this gate; retain the repository path for the
# normal in-tree invocation.
_ppm_override = os.environ.get("PPM_ASSERT_SCRIPT", "").strip()
if _ppm_override:
    PPM_ASSERT = Path(_ppm_override).expanduser()
elif (Path(__file__).resolve().parent / "ppm_assert.py").is_file():
    PPM_ASSERT = Path(__file__).resolve().parent / "ppm_assert.py"
else:
    PPM_ASSERT = ROOT / "scripts" / "t490" / "ppm_assert.py"
# The interaction page's bold `N` in `当前：N` sits here after two PageDowns.
# Keep the ROI on the digit alone: HMP can put the cursor over the sentence, so
# a wider line-level diff can mistake cursor pixels for a counter increment.
MOUSE_COUNTER_ROI = "555,625,570,650"


def run_ppm(*args: str) -> tuple[bool, str, dict[str, Any]]:
    proc = subprocess.run([sys.executable, str(PPM_ASSERT), *args],
                          text=True, capture_output=True, check=False)
    detail = (proc.stdout.strip() or proc.stderr.strip()).splitlines()
    report: dict[str, Any] = {}
    match = re.search(r"\{\"file\".*\}", proc.stdout)
    return proc.returncode == 0, detail[-1] if detail else f"rc={proc.returncode}", report


def layout_verdict(path: Path) -> tuple[bool, str]:
    """Require top-frame CSS geometry and a bottom-frame 6/6 verdict.

    The CSS page is taller than the 800-pixel output.  The driver therefore
    saves the top geometry frame as ``path`` and, when available, a second
    frame named ``after-mouse-navigation-verdict.ppm`` after scrolling to the
    document bottom.  A single-frame fallback keeps the historical behavior.
    """
    if not path.is_file():
        return False, f"missing: {path}"
    report = path.with_suffix(path.suffix + ".layout-strict-validation.json")
    proc = subprocess.run(
        [sys.executable, str(PPM_ASSERT), str(path), "--profile", "official-layout",
         "--strict", "--json", str(report), "--quiet"],
        text=True, capture_output=True, check=False,
    )
    try:
        data = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"layout strict assertion unavailable: {exc}"
    strict_failures = data.get("strict_fail_names", [])
    checks = {row.get("check"): row for row in data.get("checks", [])}
    top_core = (proc.returncode == 0 and not strict_failures
                and all(checks.get(name, {}).get("pass") for name in (
                    "official_banner", "layout_c1_flex_row",
                    "layout_c2_grid_2x2", "layout_c3_box_model")))
    top_detail = "; ".join(
        str(checks.get(name, {}).get("detail", f"missing {name}"))
        for name in ("official_banner", "layout_c1_flex_row",
                     "layout_c2_grid_2x2", "layout_c3_box_model"))

    verdict_path = path.with_name("after-mouse-navigation-verdict.ppm")
    if verdict_path.is_file():
        verdict_report = verdict_path.with_suffix(
            verdict_path.suffix + ".layout-verdict-validation.json")
        verdict_proc = subprocess.run(
            [sys.executable, str(PPM_ASSERT), str(verdict_path),
             "--profile", "official-layout", "--json", str(verdict_report),
             "--quiet"], text=True, capture_output=True, check=False,
        )
        try:
            verdict_data = json.loads(verdict_report.read_text(encoding="utf-8"))
            verdict_check = next(row for row in verdict_data.get("checks", [])
                                 if row.get("check") == "layout_verdict_pass")
        except (OSError, json.JSONDecodeError, StopIteration) as exc:
            return False, f"layout verdict assertion unavailable: {exc}"
        bottom_ok = verdict_proc.returncode == 0 and bool(verdict_check.get("pass"))
        detail = (f"top geometry={'PASS' if top_core else 'FAIL'}; "
                  f"bottom 6/6={'PASS' if bottom_ok else 'FAIL'}; "
                  f"{verdict_check.get('detail', '')}")
        return top_core and bottom_ok, detail

    # Backward-compatible single-frame path for older evidence bundles.
    check = checks.get("layout_verdict_pass", {})
    if proc.returncode != 0 or strict_failures:
        return False, f"official-layout strict failed {strict_failures}; {check.get('detail', top_detail)}"
    return bool(check.get("pass")), check.get("detail", top_detail)


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


def mouse_counter_diff(after: Path, before: Path) -> tuple[bool, str]:
    """Require a localized change in counter text, excluding cursor/button pixels."""
    return pixel_diff(after, before, MOUSE_COUNTER_ROI, 20)


def input_actions(path: Path) -> tuple[bool, str, dict[str, int]]:
    counts = {"real_key_actions": 0, "hmp_pointer_clicks": 0,
              "hmp_pointer_moves": 0, "qmp_pointer_clicks": 0,
              "qmp_absolute_moves": 0}
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
            if op == "click" and transport in {"qmp", "qmp-input-event"}:
                counts["qmp_pointer_clicks"] += 1
            if op == "absolute" and transport in {"qmp", "qmp-input-event"}:
                counts["qmp_absolute_moves"] += 1
    except OSError as exc:
        return False, str(exc), counts
    relative_ok = (counts["hmp_pointer_clicks"] >= 4
                   and counts["hmp_pointer_moves"] >= 4)
    absolute_ok = (counts["qmp_pointer_clicks"] >= 4
                   and counts["qmp_absolute_moves"] >= 4)
    ok = counts["real_key_actions"] >= 10 and (relative_ok or absolute_ok)
    return ok, ("real input actions recorded" if ok else
                "insufficient real key/pointer actions"), counts


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
    mouse_ok, mouse_detail = mouse_counter_diff(
        shots / "after-mouse-click.ppm", shots / "after-scroll.ppm")
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
        "input_transport": "QMP send-key + relative HMP or absolute QMP pointer",
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
