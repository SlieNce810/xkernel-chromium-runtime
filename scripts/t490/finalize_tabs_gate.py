#!/usr/bin/env python3
"""Recompute a tab-switch gate from an immutable completed round.

This is useful when the QMP driver completed after the outer shell was
interrupted.  It never edits screenshots or console output: the page-round
status is accepted only from the recorded ``ppm-summary.txt`` and the three
tab screenshots are rechecked with the repository pixel profiles.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def check_image(root: Path, image: Path, profile: str) -> dict[str, object]:
    if not image.is_file():
        return {"path": str(image), "exists": False, "rc": 99}
    result = subprocess.run(
        [sys.executable, str(root / "scripts/t490/ppm_assert.py"), str(image),
         "--profile", profile, "--strict", "--quiet"],
        text=True,
        capture_output=True,
    )
    return {"path": str(image), "exists": True, "rc": result.returncode}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--shots", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    args = parser.parse_args()

    evidence = args.evidence
    evidence.mkdir(parents=True, exist_ok=True)
    summary_path = evidence / "ppm-summary.txt"
    summary = summary_path.read_text(encoding="utf-8", errors="replace")
    page_round_ok = bool(
        re.search(r"GATE\s+page_fail=0\b", summary)
        and re.search(r"post_pass_fail=0\b", summary)
        and re.search(r"last_pass=1\b", summary)
    )

    checks = {
        "tab_a_before": check_image(
            args.root, args.shots / "tab-a-before.ppm", "official-index"
        ),
        "tab_b_after_ctrl_tab": check_image(
            args.root, args.shots / "tab-b-after-ctrl-tab.ppm", "official-layout"
        ),
        "tab_a_after_return": check_image(
            args.root, args.shots / "tab-a-after-return.ppm", "official-index"
        ),
    }

    result_event: dict[str, object] = {}
    if args.events.is_file():
        for line in args.events.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("kind") == "result":
                result_event = row.get("value", {})
    input_ok = bool(result_event.get("ok") is True)
    gate = page_round_ok and input_ok and all(
        value.get("rc") == 0 for value in checks.values()
    )
    payload = {
        "schema": "xkernel.tabs-gate.v2",
        "mode": "default-multiprocess",
        "sandbox_mode": "diagnostic-no-sandbox",
        "input_transport": "qmp-real-keyboard",
        "action": "ctrl-tab,ctrl-tab",
        "round_rc": 0 if page_round_ok else 1,
        "round_rc_source": "ppm-summary.txt (completed t490 round)",
        "page_round_ok": page_round_ok,
        "input_ok": input_ok,
        "result_event": result_event,
        "checks": checks,
        "pass": gate,
    }
    (evidence / "tabs-gate.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if gate else 1


if __name__ == "__main__":
    raise SystemExit(main())
