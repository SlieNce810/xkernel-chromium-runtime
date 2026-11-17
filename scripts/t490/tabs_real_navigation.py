#!/usr/bin/env python3
"""Open a second real tab through QMP keyboard input and capture both tabs."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

from qmp_input import QmpClient


ASSERT_SCRIPT = Path(__file__).with_name("ppm_assert.py")


QCODE = {
    ":": "shift:semicolon",
    "/": "slash",
    ".": "dot",
    "-": "minus",
    "_": "shift-minus",
    " ": "spc",
}


def type_url(client: QmpClient, value: str, delay: float = 0.015) -> None:
    for char in value:
        if char == ":":
            client.key_chord(["shift", "semicolon"])
        elif char == "_":
            client.key_chord(["shift", "minus"])
        else:
            client.key(QCODE.get(char, char.lower()))
        if delay:
            time.sleep(delay)


def wait_for_profile(client: QmpClient, image: Path, profile: str,
                     timeout: float, poll: float, label: str) -> bool:
    deadline = time.monotonic() + max(0.0, timeout)
    attempt = 0
    while True:
        attempt += 1
        try:
            client.screendump(image)
            proc = subprocess.run(
                [sys.executable, str(ASSERT_SCRIPT), str(image),
                 "--profile", profile, "--strict", "--quiet"],
                text=True, capture_output=True,
            )
            passed = proc.returncode == 0
            client._record("profile-check", {
                "label": label, "attempt": attempt, "profile": profile,
                "pass": passed,
            })
            if passed:
                return True
        except Exception as exc:  # QMP can close while the guest is exiting.
            client._record("profile-check-error", {
                "label": label, "attempt": attempt, "error": str(exc),
            })
        if time.monotonic() >= deadline:
            return False
        time.sleep(max(1.0, poll))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--shot-dir", required=True, type=Path)
    parser.add_argument("--wait", type=float, default=600.0,
                        help="maximum wait for each post-navigation page")
    parser.add_argument("--ready-wait", type=float, default=1000.0)
    parser.add_argument("--profile-poll", type=float, default=20.0)
    args = parser.parse_args()

    client = QmpClient(args.socket, args.output, qmp_send_key=True, input_target="auto")
    client.connect(30.0)
    args.shot_dir.mkdir(parents=True, exist_ok=True)
    client._record("checkpoint", {"name": "real-tabs-connected"})

    first_image = args.shot_dir / "tab-a-before.ppm"
    first_ready = wait_for_profile(
        client, first_image, "official-index", args.ready_wait,
        args.profile_poll, "tab-a-before",
    )

    # Create and navigate a second tab using only user-visible keyboard input.
    client.key_chord(["ctrl", "t"])
    time.sleep(2)
    client.key_chord(["ctrl", "l"])
    type_url(client, "file:///usr/share/html-test/layout.html")
    client.key("ret")
    client._record("navigation", {"url": "file:///usr/share/html-test/layout.html"})
    second_image = args.shot_dir / "tab-b-after-ctrl-tab.ppm"
    second_ready = wait_for_profile(
        client, second_image, "official-layout", args.wait,
        args.profile_poll, "tab-b-after-ctrl-tab",
    )

    client.key_chord(["ctrl", "tab"])
    third_image = args.shot_dir / "tab-a-after-return.ppm"
    third_ready = wait_for_profile(
        client, third_image, "official-index", args.wait,
        args.profile_poll, "tab-a-after-return",
    )
    ok = first_ready and second_ready and third_ready
    client._record("result", {"ok": ok, "switches": 1,
                                "first_ready": first_ready,
                                "second_ready": second_ready,
                                "third_ready": third_ready})
    client.close()
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
