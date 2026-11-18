#!/usr/bin/env python3
"""Check the minimum evidence files and stage-specific gates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


BASE_FILES = ("cmd.txt", "env.txt", "console.log", "manifest.txt", "timestamps.csv")


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def gate_passes(path: Path) -> bool:
    data = load_json(path)
    return bool(data and (data.get("pass") is True or str(data.get("result", "")).upper() == "PASS"))


def has_ppm_or_manifest(root: Path) -> bool:
    if any(root.rglob("*.ppm")):
        return True
    return any(
        path.is_file()
        and "ppm" in path.name.lower()
        and any(token in path.name.lower() for token in ("sha", "manifest", "hash"))
        for path in root.rglob("*")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument(
        "--stage",
        choices=("baseline", "precheck", "multiprocess", "sandbox", "function", "input", "stability", "perf", "report"),
        default="report",
    )
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    missing: list[str] = []

    if not evidence.is_dir():
        missing.append("evidence-directory")
    else:
        missing.extend(name for name in BASE_FILES if not (evidence / name).is_file())
        if not has_ppm_or_manifest(evidence):
            missing.append("ppm-or-sha256-manifest")
        if args.stage == "precheck" and not (evidence / "platform-compliance.txt").is_file():
            missing.append("platform-compliance.txt")
        elif args.stage == "stability":
            if not any(gate_passes(path) for path in evidence.rglob("stability-gate.json")):
                missing.append("passing-stability-gate.json")
        elif args.stage == "input":
            if not any(gate_passes(path) for path in evidence.rglob("input-gate.json")):
                missing.append("passing-input-gate.json")
        elif args.stage == "perf":
            for pattern in ("**/memory-samples.csv", "**/lifecycle-events.jsonl", "**/*validation*.json"):
                if not any(evidence.glob(pattern)):
                    missing.append(pattern)
        elif args.stage == "report":
            for name in ("acceptance.json", "acceptance-report.md"):
                if not (evidence / name).is_file():
                    missing.append(name)

    payload = {
        "schema": "xkernel.evidence-completeness.v1",
        "stage": args.stage,
        "result": "PASS" if not missing else "INCOMPLETE",
        "evidence": str(evidence),
        "missing": missing,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 1 if args.strict and missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
