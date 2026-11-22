#!/usr/bin/env python3
"""Capture an immutable, read-only T490 runtime baseline manifest.

The output directory must be new and live under ``~/xk6/evidence``. The tool
records dirty source state instead of hiding it: a binary hash, build config,
tracked diff patch, untracked file hashes, guest image, Chromium, overlay,
test pages, runner scripts, host facts, and the platform precheck result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import shutil
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def command(*args: str, cwd: Path | None = None, check: bool = True) -> str:
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr.strip()}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_record(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    path = path.resolve()
    if not path.is_file():
        return {"path": str(path), "exists": False}
    return {"path": str(path), "exists": True, "bytes": path.stat().st_size, "sha256": sha256(path)}


def read_platform(platform_env: Path) -> dict[str, str]:
    script = (
        'source "$1"; '
        'printf "PLAT_ARCH=%s\\nPLAT_MEM=%s\\nPLAT_SMP=%s\\nPLAT_ACCEL=%s\\nPLAT_CPU_TCG=%s\\nPLAT_MAKE_ARGS=%s\\n" '
        '"$PLAT_ARCH" "$PLAT_MEM" "$PLAT_SMP" "$PLAT_ACCEL" "$PLAT_CPU_TCG" "$PLAT_MAKE_ARGS"'
    )
    output = command("bash", "-c", script, "freeze-baseline", str(platform_env))
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def sha_in_image(image: Path) -> tuple[str | None, str | None, str]:
    verifier = Path(__file__).with_name("verify_chromium_image.sh")
    result = subprocess.run(
        ["bash", str(verifier), str(image), "149"],
        text=True,
        capture_output=True,
        check=False,
    )
    text = result.stdout + result.stderr
    version_match = re.search(r"CHROMIUM_IMAGE_VERSION=(.+)", text)
    sha_match = re.search(r"CHROMIUM_IMAGE_SHA256=([0-9a-f]{64})", text)
    return (version_match.group(1).strip() if version_match else None,
            sha_match.group(1) if sha_match else None,
            f"rc={result.returncode}\n{text.strip()}" )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path, help="new evidence directory under ~/xk6/evidence")
    parser.add_argument("--kernel-root", type=Path, default=Path.home() / "x-kernel")
    parser.add_argument("--base-image", type=Path, default=Path.home() / "x-kernel/images/pkg-installed.img")
    parser.add_argument("--overlay", type=Path, help="optional runtime overlay used by the measured run")
    parser.add_argument("--runner", default="run_score_page_mp.sh")
    parser.add_argument("--autorun", default="autorun_mp_diag.sh")
    parser.add_argument("--browser-extra-flags", default="--js-flags=--jitless")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    evidence_root = (root / "evidence").resolve()
    out = args.out.expanduser().resolve()
    kernel = args.kernel_root.expanduser().resolve()
    image = args.base_image.expanduser().resolve()
    overlay = args.overlay.expanduser().resolve() if args.overlay else None
    if not out.is_relative_to(evidence_root):
        parser.error(f"output must be under {evidence_root}")
    if out.exists():
        parser.error(f"refusing to overwrite existing evidence: {out}")
    if not kernel.is_dir():
        parser.error(f"kernel directory missing: {kernel}")
    platform_env = root / "scripts/t490/platform.env"
    if not platform_env.is_file():
        parser.error(f"platform config missing: {platform_env}")

    out.mkdir(parents=True)
    status = command("git", "-C", str(kernel), "status", "--porcelain=v1", "--untracked-files=all", check=False)
    diff = subprocess.run(
        ["git", "-C", str(kernel), "diff", "--binary", "HEAD"],
        text=False,
        capture_output=True,
        check=False,
    )
    (out / "kernel-status.txt").write_text(status + "\n", encoding="utf-8")
    (out / "kernel-diff.patch").write_bytes(diff.stdout)
    untracked = [line[3:] for line in status.splitlines() if line.startswith("?? ")]
    untracked_hashes = {}
    for relative in untracked:
        candidate = kernel / relative
        record = file_record(candidate)
        if candidate.is_file():
            archive_path = out / "kernel-untracked" / relative
            archive_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(candidate, archive_path)
            record["evidence_copy"] = archive_path.relative_to(out).as_posix()
        untracked_hashes[relative] = record

    try:
        platform_values = read_platform(platform_env)
    except (OSError, RuntimeError) as exc:
        platform_values = {"error": str(exc)}
    if platform_values.get("PLAT_MEM") != "2g":
        raise RuntimeError(f"formal baseline requires platform.env default 2g, found {platform_values.get('PLAT_MEM')!r}")

    qemu = shutil.which("qemu-system-aarch64")
    qemu_version = command(qemu, "--version", check=False).splitlines()[0] if qemu else "missing"
    cpuinfo = Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace")
    cpu_match = re.search(r"(?im)^(?:model name|hardware)\s*:\s*(.+)$", cpuinfo)
    lscpu = cpu_match.group(1).strip() if cpu_match else platform.processor()
    mem_total = None
    for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
        if line.startswith("MemTotal:"):
            mem_total = int(line.split()[1]) * 1024
            break
    chromium_version, chromium_sha, chromium_verify = sha_in_image(image)

    script_names = [
        "scripts/t490/platform.env",
        f"scripts/t490/{args.runner}",
        f"scripts/t490/{args.autorun}",
        "scripts/t490/t490_round.sh",
        "scripts/t490/run_session_t490.sh",
        "scripts/t490/ppm_assert.py",
        "scripts/collect_metrics.py",
        "scripts/testpage/index.html",
        "scripts/testpage/interaction.html",
        "scripts/testpage/layout.html",
    ]
    inputs = {name: file_record(root / name) for name in script_names}
    config = kernel / ".config"
    kernel_bin = kernel / "target/xkmake/kplat-aarch64/release/kernel.bin"
    build = {
        "root": str(kernel),
        "branch": command("git", "-C", str(kernel), "branch", "--show-current", check=False),
        "commit": command("git", "-C", str(kernel), "rev-parse", "HEAD", check=False),
        "describe": command("git", "-C", str(kernel), "describe", "--always", "--dirty", check=False),
        "dirty": bool(status.strip()),
        "tracked_diff_sha256": hashlib.sha256(diff.stdout).hexdigest(),
        "status_sha256": hashlib.sha256(status.encode()).hexdigest(),
        "untracked_files": untracked_hashes,
        "config": file_record(config),
        "kernel_binary": file_record(kernel_bin),
    }
    image_record = file_record(image)
    if not image_record or not image_record.get("exists"):
        raise RuntimeError(f"rootfs image missing: {image}")
    overlay_record = file_record(overlay) if overlay else {"path": "none", "exists": True, "sha256": "none"}
    payload = {
        "schema": "xkernel.t490-baseline.v1",
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "captured_at_local": command("date", "-Is", check=False),
        "host": {
            "hostname": platform.node(),
            "os": platform.platform(),
            "os_release": command("bash", "-c", ". /etc/os-release; echo \"$PRETTY_NAME\"", check=False),
            "cpu_model": lscpu or platform.processor(),
            "memory_bytes": mem_total,
        },
        "qemu": {"binary": qemu, "version": qemu_version, "accelerator": "pure TCG (platform.env ACCEL=n)"},
        "platform": platform_values,
        "kernel": build,
        "rootfs": image_record,
        "chromium": {"version": chromium_version, "sha256_in_image": chromium_sha, "verify": chromium_verify},
        "overlay": overlay_record,
        "inputs": inputs,
        "planned_runner": {
            "runner": args.runner,
            "autorun": args.autorun,
            "browser_extra_flags": args.browser_extra_flags,
            "actual_qemu_command_source": "the session cmd.txt generated by t490_round.sh",
        },
    }
    (out / "baseline.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "chromium-image-verify.txt").write_text(chromium_verify + "\n", encoding="utf-8")
    precheck = subprocess.run(
        ["bash", str(root / "scripts/t490/t490_platform_check.sh"), str(out / "platform-check.txt")],
        text=True,
        capture_output=True,
        check=False,
    )
    (out / "platform-precheck.log").write_text(
        f"cmd= bash scripts/t490/t490_platform_check.sh {out / 'platform-check.txt'}\n"
        f"rc={precheck.returncode}\n{precheck.stdout}{precheck.stderr}",
        encoding="utf-8",
    )
    sums = []
    for path in sorted(out.rglob("*")):
        if path.is_file() and path.name != "sha256sums.txt":
            sums.append(f"{sha256(path)}  {path.relative_to(out).as_posix()}")
    (out / "sha256sums.txt").write_text("\n".join(sums) + "\n", encoding="utf-8")
    print(f"BASELINE_OUT={out}")
    print(f"KERNEL_COMMIT={build['commit']} DIRTY={build['dirty']} DIFF_SHA256={build['tracked_diff_sha256']}")
    print(f"GUEST_MEMORY={platform_values.get('PLAT_MEM')} QEMU={qemu_version}")
    print(f"CHROMIUM={chromium_version or 'unverified'} CHROMIUM_SHA256={chromium_sha or 'unavailable'}")
    print(f"PLATFORM_PRECHECK_RC={precheck.returncode}")
    return precheck.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"BASELINE_FREEZE_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
