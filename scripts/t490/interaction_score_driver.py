#!/usr/bin/env python3
"""Drive the complete interaction score path on a live ready renderer.

The caller must first wait for ``official-interaction`` readiness.  Coordinates
are for the fixed 1280x800 competition page; every pointer move uses the
calibrated relative virtio-mouse path.
"""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

from qmp_input import QmpClient, click_at, type_text


def click_step4(c: QmpClient, x: int, y: int, label: str,
                count: int = 1) -> None:
    """Click through the calibrated virtio-mouse path.

    The guest's relative pointer starts outside the Weston output.  A single
    large relative move is accelerated and often lands outside the Chromium
    surface.  The working path first establishes the same off-screen origin
    used by the historical passing round, then walks to the target in 4-pixel
    events.  This remains a real QMP → virtio-mouse → evdev → libinput →
    Weston → Chromium click; it does not synthesize a DOM event.
    """
    c.relative("x", -2000)
    c.relative("y", -2000)
    for axis, target in (("x", x), ("y", y)):
        remaining = target
        while remaining > 0:
            step = min(4, remaining)
            c.relative(axis, step)
            remaining -= step
            time.sleep(0.02)
    for index in range(count):
        c.click()
        if index + 1 < count:
            # The first press after a cold surface commit can activate/focus
            # the surface.  A second real press dispatches the page control.
            time.sleep(0.8)
    c._record("checkpoint", {"name": label, "x": x, "y": y,
                              "pointer_mode": "step4",
                              "click_count": count})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--shot-dir", required=True, type=Path)
    ap.add_argument("--navigation-wait", type=float, default=45.0)
    args = ap.parse_args()
    args.shot_dir.mkdir(parents=True, exist_ok=True)
    absolute = os.environ.get("INTERACTION_ABSOLUTE", "0") == "1"
    pointer_mode = os.environ.get("INTERACTION_POINTER_MODE", "step4")
    force_hmp = os.environ.get("INTERACTION_FORCE_HMP", "0") == "1"
    c = QmpClient(args.socket, args.output, force_hmp=force_hmp,
                  qmp_send_key=True,
                  absolute_pointer=absolute, no_clamp=not absolute)
    pointer_click = (lambda x, y, label, count=1: click_at(c, x, y, label))
    if not absolute and pointer_mode == "step4":
        pointer_click = lambda x, y, label, count=1: click_step4(
            c, x, y, label, count=count)
    # The historical kiosk keyboard gate activates the surface with one
    # direct relative move.  Keep that activation separate from scored
    # controls, which use the slower step4 calibration and two presses.
    activate_pointer = lambda: click_at(c, 640, 400, "activate-window")
    try:
        c.connect(60.0)
        c._record("checkpoint", {"name": "interaction-score-connected"})

        activate_pointer()
        time.sleep(2.0)

        # The passing kiosk round first focused and activated the page's
        # self-test button.  Its resulting focus order is stable: three more
        # Tab presses then land on the text field.
        c.key("tab")
        c.key("ret")
        time.sleep(12.0)
        c.screendump(args.shot_dir / "after-selftest.ppm")

        # The self-test button retains focus after Enter; Tab visits Reset and
        # then the text field, so two additional stops are sufficient here.
        for _ in range(2):
            c.key("tab")
            time.sleep(0.3)
        c.screendump(args.shot_dir / "before-keyboard-echo.ppm")
        type_text(c, "hello x-kernel", 0.08)
        # Under pure TCG the QMP monitor accepts the keys immediately, but the
        # Wayland client and renderer can consume the queued events much later.
        time.sleep(30.0)
        c.screendump(args.shot_dir / "after-keyboard-echo.ppm")

        # End only moves the caret while the text field keeps focus.  PgDn
        # scrolls the document and brings the real-click button/link into the
        # pointer viewport.
        c.key("pgdn")
        time.sleep(5.0)
        c.key("pgdn")
        time.sleep(5.0)
        c.screendump(args.shot_dir / "after-scroll.ppm")
        pointer_click(281, 674, "real-click-plus-one", count=2)
        time.sleep(2.0)
        c.screendump(args.shot_dir / "after-mouse-click.ppm")

        pointer_click(500, 710, "mouse-click-navigation", count=2)
        time.sleep(args.navigation_wait)
        c.screendump(args.shot_dir / "after-mouse-navigation.ppm")
        c._record("result", {"ok": True})
        return 0
    finally:
        c.close()


if __name__ == "__main__":
    raise SystemExit(main())
