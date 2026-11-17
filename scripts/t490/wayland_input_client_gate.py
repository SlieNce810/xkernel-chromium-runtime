#!/usr/bin/env python3
"""Validate Wayland client-side keyboard/pointer delivery from WAYLAND_DEBUG.

The eventdemo probe proves Weston can deliver input to a Wayland client.  This
gate is the next hop: it consumes Chromium's ``WAYLAND_DEBUG=client`` stderr
and requires the actual browser client to receive enter/key and enter/button
protocol messages.  It does not infer input delivery from QMP success or from
an unchanged screenshot.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


PATTERNS = {
    "keyboard_enter": re.compile(r"wl_keyboard[^\n]*[.:]enter\b"),
    "keyboard_key": re.compile(r"wl_keyboard[^\n]*[.:]key\b"),
    "pointer_enter": re.compile(r"wl_pointer[^\n]*[.:]enter\b"),
    "pointer_motion": re.compile(r"wl_pointer[^\n]*[.:]motion\b"),
    "pointer_button": re.compile(r"wl_pointer[^\n]*[.:]button\b"),
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", type=Path)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    if not args.log.is_file():
        payload = {"schema": "xkernel.wayland-input-client.v1",
                   "result": "FAIL", "error": f"missing: {args.log}"}
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 1 if args.strict else 2

    text = args.log.read_text(encoding="utf-8", errors="replace")
    counts = {name: len(pattern.findall(text))
              for name, pattern in PATTERNS.items()}
    required = ("keyboard_enter", "keyboard_key", "pointer_enter",
                "pointer_button")
    missing = [name for name in required if counts[name] == 0]
    payload = {
        "schema": "xkernel.wayland-input-client.v1",
        "result": "PASS" if not missing else "FAIL",
        "log": str(args.log),
        "counts": counts,
        "required": list(required),
        "missing": missing,
    }
    encoded = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if (not args.strict or not missing) else 1


if __name__ == "__main__":
    raise SystemExit(main())
