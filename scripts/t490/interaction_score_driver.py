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

from interaction_score_gate import pixel_diff
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
    ap.add_argument("--keyboard-echo-timeout", type=float, default=120.0,
                    help="maximum time to wait for guest keyboard echo under slow TCG")
    ap.add_argument("--keyboard-echo-poll", type=float, default=10.0,
                    help="screenshot interval while waiting for keyboard echo")
    ap.add_argument("--focus-settle", type=float, default=3.0,
                    help="delay after each Tab before saving the focus screenshot")
    ap.add_argument("--scroll-settle", type=float, default=5.0,
                    help="delay after each PageDown before saving the scroll screenshot")
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
        for index in range(1, 3):
            c.key("tab")
            time.sleep(args.focus_settle)
            focus_shot = args.shot_dir / f"focus-after-tab-{index}.ppm"
            c.screendump(focus_shot)
            c._record("checkpoint", {"name": f"focus-after-tab-{index}",
                                      "screenshot": focus_shot.name,
                                      "settle_seconds": args.focus_settle})
        before_echo = args.shot_dir / "before-keyboard-echo.ppm"
        after_echo = args.shot_dir / "after-keyboard-echo.ppm"
        c.screendump(before_echo)
        type_text(c, "hello x-kernel", 0.08)
        # Under pure TCG the QMP monitor accepts keys before Chromium consumes
        # them. Keep sampling the same viewport until the text is visible, so
        # the fixed keyboard ROI is compared before scrolling moves it.
        echo_pass = False
        echo_attempt = 0
        deadline = time.monotonic() + max(0.0, args.keyboard_echo_timeout)
        while time.monotonic() < deadline:
            time.sleep(min(args.keyboard_echo_poll,
                           max(0.0, deadline - time.monotonic())))
            echo_attempt += 1
            candidate = args.shot_dir / f"keyboard-echo-sample-{echo_attempt:02d}.ppm"
            c.screendump(candidate)
            echo_pass, echo_detail = pixel_diff(
                candidate, before_echo, "220,670,1045,765", 200)
            c._record("checkpoint", {
                "name": "keyboard-echo-sample",
                "attempt": echo_attempt,
                "screenshot": candidate.name,
                "pass": echo_pass,
                "detail": echo_detail,
            })
            if echo_pass:
                candidate.replace(after_echo)
                break
        if not echo_pass:
            if echo_attempt:
                candidate.replace(after_echo)
            else:
                c.screendump(after_echo)

        # End only moves the caret while the text field keeps focus.  PgDn
        # scrolls the document and brings the real-click button/link into the
        # pointer viewport.
        for index in range(1, 3):
            c.key("pgdn")
            time.sleep(args.scroll_settle)
            scroll_shot = args.shot_dir / f"after-pgdn-{index}.ppm"
            c.screendump(scroll_shot)
            c._record("checkpoint", {"name": f"after-pgdn-{index}",
                                      "screenshot": scroll_shot.name,
                                      "settle_seconds": args.scroll_settle})
        c.screendump(args.shot_dir / "after-scroll.ppm")
        # Relative virtio-mouse acceleration moved the cursor to about
        # (320, 749) for the earlier (281, 674) request. Compensate the
        # measured lower-right drift before clicking the counter.
        pointer_click(247, 607, "real-click-plus-one", count=2)
        time.sleep(2.0)
        c.screendump(args.shot_dir / "after-mouse-click.ppm")

        # The CSS link is centered near (350, 710); apply the same measured
        # relative-pointer correction before the navigation click.
        pointer_click(292, 638, "mouse-click-navigation", count=2)
        time.sleep(args.navigation_wait)
        c.screendump(args.shot_dir / "after-mouse-navigation.ppm")
        c._record("result", {"ok": True})
        return 0
    finally:
        c.close()


if __name__ == "__main__":
    raise SystemExit(main())
