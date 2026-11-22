#!/usr/bin/env python3
"""Capture a read-only manifest of the acceptance scripts and frozen inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


INPUTS = (
    "README.md",
    "docs/决赛剩余任务复现与统一验收.md",
    "scripts/final-acceptance.sh",
    "scripts/t490/platform.env",
    "scripts/t490/t490_round.sh",
    "scripts/t490/run_tabs_round_mp.sh",
    "scripts/t490/run_input_final.sh",
    "scripts/t490/run_javascript_round_mp.sh",
    "scripts/t490/run_score_page_mp.sh",
    "scripts/t490/autorun_mp_score_observe6.sh",
    "scripts/t490/ppm_assert.py",
    "scripts/t490/run_stability_round_mp.sh",
    "scripts/t490/stability_driver.py",
    "scripts/t490/wait_page_ready.py",
    "scripts/t490/qmp_input.py",
    "scripts/collect_metrics.py",
    "scripts/compare_perf.py",
    "scripts/run_perf_plan.py",
    "scripts/testpage/index.html",
    "scripts/testpage/interaction.html",
    "scripts/testpage/layout.html",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(root: Path, *args: str) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), *args], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        pass

    # A Windows Git worktree mounted into WSL can contain a .git file whose
    # worktree target is a Windows drive path. Linux Git cannot resolve that
    # target, so fall back to Git for Windows without changing global config.
    git_exe = shutil.which("git.exe")
    wslpath = shutil.which("wslpath")
    if git_exe and wslpath:
        try:
            windows_root = subprocess.check_output(
                [wslpath, "-w", str(root)], text=True, stderr=subprocess.DEVNULL
            ).strip()
            return subprocess.check_output(
                [git_exe, "-C", windows_root, *args], text=True, stderr=subprocess.DEVNULL
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            pass
    return None


def git_snapshot(path: Path) -> dict[str, str | None]:
    return {
        "root": str(path),
        "commit": git(path, "rev-parse", "HEAD"),
        "branch": git(path, "branch", "--show-current"),
        "status_porcelain": git(path, "status", "--porcelain"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--kernel-root", type=Path)
    parser.add_argument("--freeze-manifest", type=Path)
    args = parser.parse_args()

    root = args.root.resolve()
    tracked_inputs: dict[str, dict[str, int | str]] = {}
    missing_inputs: list[str] = []
    for relative in INPUTS:
        path = root / relative
        if not path.is_file():
            missing_inputs.append(relative)
            continue
        tracked_inputs[relative] = {"bytes": path.stat().st_size, "sha256": sha256(path)}

    freeze_path = args.freeze_manifest
    if freeze_path is None:
        freeze_path = root / "evidence/2026-11-17_t490-goal-baseline-freeze-r3/baseline.json"
    freeze_path = freeze_path.resolve()
    freeze = None
    if freeze_path.is_file():
        freeze = {
            "path": str(freeze_path),
            "bytes": freeze_path.stat().st_size,
            "sha256": sha256(freeze_path),
        }

    repository = git_snapshot(root)
    freeze_ok = freeze is not None
    git_ok = repository["commit"] is not None and repository["branch"] is not None
    payload = {
        "schema": "xkernel.baseline-inventory.v1",
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": {"platform": platform.platform(), "python": platform.python_version()},
        "repository": repository,
        "kernel_repository": git_snapshot(args.kernel_root.resolve()) if args.kernel_root else None,
        "frozen_baseline_manifest": freeze,
        "inputs": tracked_inputs,
        "missing_inputs": missing_inputs,
        "result": "PASS" if not missing_inputs and freeze_ok and git_ok else "INCOMPLETE",
        "checks": {
            "required_inputs": "PASS" if not missing_inputs else "INCOMPLETE",
            "frozen_manifest": "PASS" if freeze_ok else "INCOMPLETE",
            "git_identity": "PASS" if git_ok else "INCOMPLETE",
        },
    }
    output = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0 if payload["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
