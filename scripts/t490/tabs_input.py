#!/usr/bin/env python3
"""Drive a real Ctrl+Tab -> Ctrl+Tab cycle through QEMU QMP.

The helper deliberately does not use CDP or page JavaScript.  It only sends
the same keyboard event a user would send to the guest keyboard and records a
screendump before, after, and after returning to the first tab.  The caller
uses the three screenshots and this JSONL transcript as the tab-switch gate.
"""

from __future__ import annotations

import argparse
import sys
import subprocess
import time
from pathlib import Path

from qmp_input import QmpClient, QmpError


ASSERT_SCRIPT = Path(__file__).with_name("ppm_assert.py")


def assert_profile(image: Path, profile: str) -> bool:
    """Return whether an image satisfies the strict competition profile."""
    if not profile or not image.exists() or not ASSERT_SCRIPT.exists():
        return False
    proc = subprocess.run(
        [sys.executable, str(ASSERT_SCRIPT), str(image), "--profile", profile,
         "--strict", "--quiet"],
        text=True,
        capture_output=True,
    )
    return proc.returncode == 0


def wait_for_profile(client: QmpClient, image: Path, profile: str,
                     timeout: float, poll: float, label: str) -> bool:
    """Keep taking real QMP screenshots until a page profile passes."""
    deadline = time.monotonic() + max(0.0, timeout)
    attempt = 0
    while True:
        attempt += 1
        try:
            client.screendump(image)
        except (OSError, QmpError) as exc:
            client._record("profile-check-error", {
                "label": label, "attempt": attempt, "error": str(exc),
            })
        else:
            passed = assert_profile(image, profile)
            client._record("profile-check", {
                "label": label, "attempt": attempt, "profile": profile,
                "pass": passed,
            })
            if passed:
                return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(max(1.0, poll))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--shot-dir", required=True, type=Path)
    parser.add_argument("--connect-timeout", type=float, default=300.0)
    parser.add_argument("--ready-wait", type=float, default=90.0)
    parser.add_argument("--settle", type=float, default=8.0)
    parser.add_argument("--ready-profile", default="",
                        help="wait for this strict profile before first Ctrl+Tab")
    parser.add_argument("--switch-profile", default="",
                        help="wait for this strict profile after first Ctrl+Tab")
    parser.add_argument("--switch-timeout", type=float, default=300.0)
    parser.add_argument("--profile-poll", type=float, default=20.0)
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.shot_dir.mkdir(parents=True, exist_ok=True)
    client = QmpClient(
        args.socket,
        args.output,
        qmp_send_key=True,
        input_target="auto",
    )
    try:
        client.connect(args.connect_timeout)
        client._record("checkpoint", {"name": "tabs-qmp-connected"})
        first_image = args.shot_dir / "tab-a-before.ppm"
        if args.ready_profile:
            first_ready = wait_for_profile(
                client, first_image, args.ready_profile,
                args.ready_wait, args.profile_poll, "tab-a-before",
            )
        else:
            time.sleep(args.ready_wait)
            client.screendump(first_image)
            first_ready = True
        client._record("checkpoint", {"name": "tab-a-before"})

        client.key_chord(["ctrl", "tab"])
        second_image = args.shot_dir / "tab-b-after-ctrl-tab.ppm"
        if args.switch_profile:
            second_ready = wait_for_profile(
                client, second_image, args.switch_profile,
                args.switch_timeout, args.profile_poll,
                "tab-b-after-ctrl-tab",
            )
        else:
            time.sleep(args.settle)
            client.screendump(second_image)
            second_ready = True
        client._record("checkpoint", {"name": "tab-b-after-ctrl-tab"})

        client.key_chord(["ctrl", "tab"])
        third_image = args.shot_dir / "tab-a-after-return.ppm"
        if args.ready_profile:
            third_ready = wait_for_profile(
                client, third_image, args.ready_profile,
                args.switch_timeout, args.profile_poll,
                "tab-a-after-return",
            )
        else:
            time.sleep(args.settle)
            client.screendump(third_image)
            third_ready = True
        client._record("checkpoint", {"name": "tab-a-after-return"})
        ok = first_ready and second_ready and third_ready
        client._record("result", {"ok": ok, "switches": 2,
                                    "first_ready": first_ready,
                                    "second_ready": second_ready,
                                    "third_ready": third_ready})
        return 0 if ok else 1
    except (OSError, QmpError, TimeoutError) as exc:
        try:
            client._record("result", {"ok": False, "error": str(exc)})
        except OSError:
            pass
        print(f"tabs_input: {exc}", file=sys.stderr)
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
