#!/usr/bin/env python3
"""Set the named GTK/X11 client size before the guest starts (native Linux)."""
from __future__ import annotations

import ctypes as c
import ctypes.util
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path


class SizeHints(c.Structure):
    _fields_ = [("flags", c.c_long)] + [(name, c.c_int) for name in (
        "x", "y", "width", "height", "min_width", "min_height", "max_width",
        "max_height", "width_inc", "height_inc", "min_aspect_x", "min_aspect_y",
        "max_aspect_x", "max_aspect_y", "base_width", "base_height", "win_gravity")]


def preflight() -> None:
    if not os.environ.get("DISPLAY"):
        raise RuntimeError("GTK mode needs the Linux desktop DISPLAY and XAUTHORITY")
    if not shutil.which("xwininfo") or not c.util.find_library("X11"):
        raise RuntimeError("GTK sizing needs xwininfo (x11-utils) and libX11")


def geometry(window: int) -> dict[str, int]:
    info = subprocess.check_output(["xwininfo", "-id", hex(window)], text=True)
    return {key.lower(): int(re.search(r"\b" + key + r":\s+(\d+)", info)[1])
            for key in ("Width", "Height")}


def fix_window(name: str, width: int, height: int, output: str, pump) -> None:
    deadline = time.monotonic() + 60
    window = None
    while time.monotonic() < deadline:
        pump(0.2)
        tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
        for line in tree.splitlines():
            if name in line and '"qemu" "Qemu-system-aarch64"' in line:
                window = int(line.split()[0], 16)
                break
        if window:
            break
        time.sleep(0.1)
    if window is None:
        raise RuntimeError("Named QEMU GTK/X11 window did not appear within 60 seconds")

    x = c.CDLL(c.util.find_library("X11"))
    x.XOpenDisplay.argtypes = [c.c_char_p]
    x.XOpenDisplay.restype = c.c_void_p
    x.XSetWMNormalHints.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(SizeHints)]
    x.XResizeWindow.argtypes = [c.c_void_p, c.c_ulong, c.c_uint, c.c_uint]
    x.XFlush.argtypes = [c.c_void_p]
    x.XCloseDisplay.argtypes = [c.c_void_p]
    display = x.XOpenDisplay(None)
    if not display:
        raise RuntimeError("Cannot open X11 display; check desktop XAUTHORITY")
    try:
        hints = SizeHints()
        hints.flags = (1 << 4) | (1 << 5)  # PMinSize | PMaxSize
        hints.min_width = hints.max_width = width
        hints.min_height = hints.max_height = height
        x.XSetWMNormalHints(display, window, c.byref(hints))
        x.XResizeWindow(display, window, width, height)
        x.XFlush(display)
        stable = 0
        while time.monotonic() < deadline:
            pump(0.2)
            actual = geometry(window)
            stable = stable + 1 if actual == {"width": width, "height": height} else 0
            if stable >= 5:
                Path(output).write_text(json.dumps({
                    "mode": "gtk-x11", "window": hex(window),
                    "client": actual, "menubar": False, "fixed_size": True,
                    "guest_started_after_sizing": True,
                }, indent=2) + "\n", encoding="utf-8")
                return
            time.sleep(0.1)
        raise RuntimeError(f"Window size did not settle at {width}x{height}: {actual}")
    finally:
        x.XCloseDisplay(display)


def check_ppm(path: str, width: int, height: int) -> None:
    with open(path, "rb") as stream:
        tokens = []
        while len(tokens) < 4:
            line = stream.readline()
            if not line:
                raise RuntimeError(f"Invalid PPM header: {path}")
            tokens.extend(line.split(b"#", 1)[0].split())
    if tokens[:3] != [b"P6", str(width).encode(), str(height).encode()]:
        raise RuntimeError(f"Expected {width}x{height} framebuffer, got {tokens[:3]}: {path}")
