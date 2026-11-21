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
from typing import Mapping

from interaction_score_gate import mouse_counter_diff, pixel_diff
from qmp_input import QmpClient, click_at, type_text


def click_step(c: QmpClient, x: int, y: int, label: str, count: int = 1,
               step_size: int = 4, step_delay: float = 0.02) -> None:
    """Click through a real relative virtio-mouse path.

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
            step = min(step_size, remaining)
            c.relative(axis, step)
            remaining -= step
            time.sleep(step_delay)
    for index in range(count):
        c.click()
        if index + 1 < count:
            # The first press after a cold surface commit can activate/focus
            # the surface.  A second real press dispatches the page control.
            time.sleep(0.8)
    c._record("checkpoint", {"name": label, "x": x, "y": y,
                              "pointer_mode": f"step{step_size}",
                              "click_count": count})


def pointer_targets(pointer_mode: str) -> tuple[tuple[int, int], tuple[int, int]]:
    """Return counter and CSS-link movement requests for each relative mode.

    INTERACTION_COUNTER_TARGET and INTERACTION_NAV_TARGET may override a
    request as ``x,y``. The step3 defaults use screenshot-measured HMP cursor
    hot-spots from the last in-frame R18 trial. R19's two-point extrapolation
    left the viewport, so it is retained only as a failed experiment in the
    report. Defaults remain candidates until the actual click gates pass.
    """
    return pointer_targets_from_env(pointer_mode, os.environ)


def pointer_targets_from_env(
    pointer_mode: str, env: Mapping[str, str]
) -> tuple[tuple[int, int], tuple[int, int]]:
    """Resolve per-run pointer targets without editing the driver."""
    if pointer_mode == "step3":
        defaults = ((250, 588), (350, 710))
    elif pointer_mode == "step1":
        defaults = ((281, 674), (350, 710))
    else:
        defaults = ((247, 607), (292, 638))

    def parse(name: str, fallback: tuple[int, int]) -> tuple[int, int]:
        raw = env.get(name)
        if raw is None:
            return fallback
        parts = raw.split(",")
        if len(parts) != 2:
            raise ValueError(f"{name} must be x,y, got {raw!r}")
        try:
            x, y = (int(part.strip()) for part in parts)
        except ValueError as exc:
            raise ValueError(f"{name} must contain two integers, got {raw!r}") from exc
        if not all(0 <= value <= 4096 for value in (x, y)):
            raise ValueError(f"{name} coordinates must be in 0..4096, got {raw!r}")
        return x, y

    return (parse("INTERACTION_COUNTER_TARGET", defaults[0]),
            parse("INTERACTION_NAV_TARGET", defaults[1]))


def counter_retry_targets_from_env(env: Mapping[str, str]) -> tuple[tuple[int, int], ...]:
    """Parse optional ordered retry requests, written as ``x,y;x,y``."""
    raw = env.get("INTERACTION_COUNTER_RETRY_TARGETS", "").strip()
    if not raw:
        return ()
    targets: list[tuple[int, int]] = []
    for index, item in enumerate(raw.split(";"), 1):
        parts = item.split(",")
        if len(parts) != 2:
            raise ValueError(
                f"INTERACTION_COUNTER_RETRY_TARGETS item {index} must be x,y"
            )
        try:
            x, y = (int(part.strip()) for part in parts)
        except ValueError as exc:
            raise ValueError(
                f"INTERACTION_COUNTER_RETRY_TARGETS item {index} must contain integers"
            ) from exc
        if not all(0 <= value <= 4096 for value in (x, y)):
            raise ValueError(
                f"INTERACTION_COUNTER_RETRY_TARGETS item {index} must be in 0..4096"
            )
        targets.append((x, y))
    return tuple(targets)


def click_counter_with_retries(
    c: QmpClient,
    *,
    pointer_click,
    initial_target: tuple[int, int],
    retry_targets: tuple[tuple[int, int], ...],
    baseline: Path,
    after_path: Path,
    shot_dir: Path,
) -> tuple[bool, int]:
    """Try real pointer requests until the rendered counter ROI changes.

    Every request is a fresh relative HMP path and two real button presses. A
    screenshot is checked against the same pre-click frame before another
    request is sent; the first passing frame becomes ``after_path``.
    """
    targets = (initial_target, *retry_targets)
    last_shot: Path | None = None
    for attempt, (x, y) in enumerate(targets, 1):
        label = f"real-click-plus-one-attempt-{attempt}"
        pointer_click(x, y, label, count=2)
        time.sleep(2.0)
        candidate = shot_dir / f"counter-attempt-{attempt}.ppm"
        c.screendump(candidate)
        passed, detail = mouse_counter_diff(candidate, baseline)
        c._record("checkpoint", {
            "name": "mouse-counter-attempt",
            "attempt": attempt,
            "x": x,
            "y": y,
            "screenshot": candidate.name,
            "pass": passed,
            "detail": detail,
        })
        last_shot = candidate
        if passed:
            candidate.replace(after_path)
            return True, attempt
    if last_shot is not None:
        last_shot.replace(after_path)
    return False, len(targets)


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
    ready_settle = float(os.environ.get("INTERACTION_READY_SETTLE_SECONDS", "5"))
    selftest_target_raw = os.environ.get("INTERACTION_SELFTEST_TARGET", "272,195")
    try:
        selftest_x, selftest_y = (int(part.strip()) for part in selftest_target_raw.split(","))
    except ValueError as exc:
        raise SystemExit(
            f"INTERACTION_SELFTEST_TARGET must be x,y, got {selftest_target_raw!r}"
        ) from exc
    c = QmpClient(args.socket, args.output, force_hmp=force_hmp,
                  qmp_send_key=True,
                  absolute_pointer=absolute, no_clamp=not absolute)
    pointer_click = (lambda x, y, label, count=1: click_at(c, x, y, label))
    if not absolute and pointer_mode in {"step1", "step3", "step4"}:
        step_size = int(pointer_mode.removeprefix("step"))
        step_delay = 0.05 if step_size == 1 else 0.02
        pointer_click = lambda x, y, label, count=1: click_step(
            c, x, y, label, count=count,
            step_size=step_size, step_delay=step_delay)
    # The historical kiosk keyboard gate activates the surface with one
    # direct relative move.  Keep that activation separate from scored
    # controls, which use the slower step4 calibration and two presses.
    activate_pointer = lambda: click_at(c, 640, 400, "activate-window")
    try:
        c.connect(60.0)
        c._record("checkpoint", {"name": "interaction-score-connected"})

        # A strict readiness frame can arrive while Chromium is still
        # committing the same navigation.  Let the compositor settle before
        # sending scored input; otherwise the first keyboard samples can be
        # blank even though the ready frame itself passed.
        if ready_settle > 0:
            time.sleep(ready_settle)
        c._record("checkpoint", {"name": "interaction-ready-settle",
                                  "seconds": ready_settle})

        # With an absolute tablet, click the visible self-test control twice:
        # the first press may only activate the Wayland surface and the second
        # dispatches the button.  This keeps the JS gate on a real pointer
        # path and avoids relying on a Tab focus order that is intermittent
        # under pure TCG.  Relative/HMP rounds retain the historical
        # Tab+Enter activation path.
        if absolute:
            click_at(c, selftest_x, selftest_y, "activate-selftest-button")
            time.sleep(1.0)
            click_at(c, selftest_x, selftest_y, "run-selftest-button")
        else:
            activate_pointer()
            time.sleep(2.0)
            c.key("tab")
            c.key("ret")
        time.sleep(12.0)
        c.screendump(args.shot_dir / "after-selftest.ppm")

        # The self-test button retains focus after a click or Enter; Tab visits
        # Reset and then the text field, so two stops are sufficient here.
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
        counter_target, nav_target = pointer_targets(pointer_mode)
        retry_targets = counter_retry_targets_from_env(os.environ)
        counter_pass, counter_attempts = click_counter_with_retries(
            c,
            pointer_click=pointer_click,
            initial_target=counter_target,
            retry_targets=retry_targets,
            baseline=args.shot_dir / "after-scroll.ppm",
            after_path=args.shot_dir / "after-mouse-click.ppm",
            shot_dir=args.shot_dir,
        )
        c._record("checkpoint", {
            "name": "mouse-counter-summary",
            "pass": counter_pass,
            "attempts": counter_attempts,
        })

        pointer_click(*nav_target, "mouse-click-navigation", count=2)
        time.sleep(args.navigation_wait)
        for index in range(1, 4):
            c.key("pgup")
            time.sleep(1.0)
            c._record("checkpoint", {"name": "layout-pageup",
                                      "attempt": index,
                                      "settle_seconds": 1.0})
        time.sleep(2.0)
        c._record("checkpoint", {"name": "layout-return-to-top",
                                  "method": "pageup",
                                  "settle_seconds": 2.0})
        c.screendump(args.shot_dir / "after-mouse-navigation.ppm")
        # The layout page is taller than the 800-pixel output.  Keep the top
        # geometry frame above and capture a second frame at the document
        # bottom so the green 6/6 verdict is independently visible.
        for index in range(1, 9):
            c.key("pgdn")
            time.sleep(0.5)
        c.key("end")
        time.sleep(3.0)
        c._record("checkpoint", {"name": "layout-verdict-bottom",
                                  "method": "pgdn-plus-end",
                                  "settle_seconds": 3.0})
        c.screendump(args.shot_dir / "after-mouse-navigation-verdict.ppm")
        c._record("result", {"ok": True})
        return 0
    finally:
        c.close()


if __name__ == "__main__":
    raise SystemExit(main())
