#!/usr/bin/env python3
"""Recompute the final-goal status from committed evidence."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


SCORE_ITEMS = ("html", "process_structure", "tabs", "input", "javascript", "css")
SCORE_POINTS = {"html": 4, "process_structure": 4, "tabs": 4, "input": 4, "javascript": 2, "css": 2}
GATE_NAMES = {
    "tabs": ("tabs-gate.json",),
    "input": ("input-gate.json",),
    "javascript": ("javascript-gate.json",),
    "css": ("score-page-gate.json", "css-gate.json"),
}


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def is_2g(directory: Path) -> bool:
    for suffix in ("-review", "-platform-check", "-precheck"):
        if directory.name.endswith(suffix):
            source = directory.with_name(directory.name[: -len(suffix)])
            if source.is_dir():
                return is_2g(source)

    manifest = read_text(directory / "manifest.txt")
    for line in manifest.splitlines():
        if "make_argv" in line:
            match = re.search(r"\bMEM=(\d+)g\b", line, flags=re.IGNORECASE)
            if match:
                return match.group(1) == "2"

    command = read_text(directory / "cmd.txt")
    match = re.search(r"(?:^|\s)-m\s+(\d+)g(?:\s|$)", command, flags=re.MULTILINE)
    if match:
        return match.group(1) == "2"
    match = re.search(r"\bMEM=(\d+)g\b", command, flags=re.IGNORECASE)
    if match:
        return match.group(1) == "2"

    config = read_text(directory / "stability-run-config.txt")
    match = re.search(r"^memory=(\d+)g$", config, flags=re.MULTILINE)
    if match:
        return match.group(1) == "2"
    return False


def gate_passes(path: Path) -> bool:
    data = load_json(path)
    if data is None:
        return False
    if data.get("pass") is True or str(data.get("result", "")).upper() == "PASS":
        return True
    if path.name == "score-page-gate.json":
        rows = data.get("screenshots", [])
        return bool(rows) and int(data.get("round_rc", 1)) == 0 and any(
            isinstance(row, dict) and int(row.get("rc", 1)) == 0 for row in rows
        )
    return False


def score_feature(root: Path, feature: str) -> dict[str, Any]:
    evidence = root / "evidence"
    if feature == "html":
        cold_runs = []
        for path in sorted(evidence.glob("*_t490-goal2g-index-cold0[1-3]")):
            summary = read_text(path / "ppm-summary.txt")
            if is_2g(path) and "page_fail=0" in summary and "last_pass=1" in summary:
                cold_runs.append(str(path.relative_to(root)))
        return {
            "status": "PASS" if len(cold_runs) >= 3 else "INCOMPLETE",
            "evidence": cold_runs,
            "required_independent_cold_starts": 3,
        }

    if feature == "process_structure":
        candidates = sorted(evidence.rglob("process-structure-summary.json"))
    else:
        candidates = sorted(path for name in GATE_NAMES[feature] for path in evidence.rglob(name))
    passing = []
    for gate in candidates:
        directory = gate.parent
        if directory.name == "process-structure":
            directory = directory.parent
        data = load_json(gate)
        if feature == "css" and data and data.get("item") != "css" and data.get("page_profile") != "official-layout":
            continue
        if is_2g(directory) and gate_passes(gate):
            passing.append(str(gate.relative_to(root)))
    return {"status": "PASS" if passing else "INCOMPLETE", "evidence": passing}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    evidence = root / "evidence"

    freeze = evidence / "2026-11-17_t490-goal-baseline-freeze-r3/baseline.json"
    cold_reports = [
        root / "report/287-T490-2GiB默认多进程首页冷启动首轮-20261117.md",
        root / "report/288-T490-2GiB默认多进程首页冷启动第二轮-20261117.md",
        root / "report/289-T490-2GiB默认多进程首页冷启动第三轮-20261118.md",
    ]
    cold_status = "PASS" if freeze.is_file() and all(path.is_file() for path in cold_reports) else "INCOMPLETE"
    score = {item: score_feature(root, item) for item in SCORE_ITEMS}
    score_status = "PASS" if all(row["status"] == "PASS" for row in score.values()) else "INCOMPLETE"
    score_points = sum(SCORE_POINTS[item] for item, row in score.items() if row["status"] == "PASS")

    stability_gates = []
    for gate in evidence.rglob("stability-gate.json"):
        data = load_json(gate)
        if data and data.get("pass") is True and is_2g(gate.parent):
            stability_gates.append(str(gate.relative_to(root)))
    stability_status = "PASS" if stability_gates else "INCOMPLETE"

    compatibility_path = evidence / "compatibility-final/summary.json"
    compatibility = load_json(compatibility_path) if compatibility_path.exists() else None
    compatibility_status = (
        "PASS" if compatibility and compatibility.get("result") == "PASS" and not compatibility.get("pending")
        else "INCOMPLETE"
    )
    compatibility_pending = [] if compatibility_status == "PASS" else [
        "inotify Linux/x-kernel comparison and browser watcher regression",
        "timerfd frozen-version probe and regression",
        "namespace and SCM_RIGHTS short-read compatibility boundaries",
        "mmap/COW/fork/unmap residency accounting under the frozen kernel hash",
        "procfs PSS/USS and shared-page accounting",
    ]

    perf_path = evidence / "perf/final-summary.json"
    perf = load_json(perf_path) if perf_path.exists() else None
    required_metrics = {"browser_start", "first_frame", "renderer_create", "peak_memory"}
    present_metrics = set(perf.get("valid_metrics", [])) if perf else set()
    before_runs = int(perf.get("before_runs", 0)) if perf else 0
    after_runs = int(perf.get("after_runs", 0)) if perf else 0
    perf_status = (
        "PASS" if perf and required_metrics.issubset(present_metrics) and before_runs >= 5 and after_runs >= 5
        else "INCOMPLETE"
    )

    overall = "PASS" if all(status == "PASS" for status in (
        cold_status, score_status, stability_status, compatibility_status, perf_status
    )) else "INCOMPLETE"
    payload = {
        "schema": "xkernel.final-goal-audit.v1",
        "result": overall,
        "baseline_freeze": {"status": "PASS" if freeze.is_file() else "INCOMPLETE", "path": str(freeze.relative_to(root))},
        "three_cold_starts_2g": {"status": cold_status, "reports": [str(path.relative_to(root)) for path in cold_reports]},
        "browser_score_2g": {
            "status": score_status,
            "points": score_points,
            "max_points": 20,
            "items": score,
        },
        "stability_2g": {"status": stability_status, "passing_gates": stability_gates},
        "compatibility": {"status": compatibility_status, "pending": compatibility_pending},
        "performance": {
            "status": perf_status,
            "required_metrics": sorted(required_metrics),
            "present_metrics": sorted(present_metrics),
            "before_runs": before_runs,
            "after_runs": after_runs,
        },
    }
    output = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    print(output, end="")
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(output, encoding="utf-8")
    return 1 if args.strict and overall != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
