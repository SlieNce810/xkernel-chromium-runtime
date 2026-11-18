#!/usr/bin/env python3
"""Regression tests for the CSS navigation page identity gate."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from interaction_score_gate import (
    MOUSE_COUNTER_ROI,
    layout_verdict,
    mouse_counter_diff,
)


class LayoutVerdictTests(unittest.TestCase):
    def _run_gate(self, strict_fail_names: list[str], returncode: int) -> tuple[bool, str]:
        with tempfile.TemporaryDirectory() as directory:
            ppm = Path(directory) / "after-mouse-navigation.ppm"
            ppm.write_bytes(b"fixture")

            def fake_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
                report_path = Path(command[command.index("--json") + 1])
                report_path.write_text(
                    json.dumps({
                        "profile": "official-layout",
                        "strict_fail_names": strict_fail_names,
                        "checks": [{
                            "check": "layout_verdict_pass",
                            "pass": True,
                            "detail": "green verdict bar present",
                        }],
                    }),
                    encoding="utf-8",
                )
                return SimpleNamespace(returncode=returncode, stdout="", stderr="")

            with patch("interaction_score_gate.subprocess.run", side_effect=fake_run):
                return layout_verdict(ppm)

    def test_green_verdict_alone_does_not_prove_layout_navigation(self) -> None:
        passed, detail = self._run_gate(
            ["layout_c1_flex_row", "layout_c2_grid_2x2", "layout_c3_box_model"], 1
        )
        self.assertFalse(passed)
        self.assertIn("official-layout strict failed", detail)

    def test_layout_verdict_requires_full_strict_profile(self) -> None:
        passed, detail = self._run_gate([], 0)
        self.assertTrue(passed)
        self.assertEqual("green verdict bar present", detail)


class MouseCounterGateTests(unittest.TestCase):
    @staticmethod
    def _write_ppm(path: Path, black_pixels: set[tuple[int, int]]) -> None:
        width, height = 1280, 800
        raster = bytearray([255]) * (width * height * 3)
        for x, y in black_pixels:
            offset = (y * width + x) * 3
            raster[offset:offset + 3] = b"\x00\x00\x00"
        path.write_bytes(b"P6\n1280 800\n255\n" + raster)

    def test_mouse_counter_roi_is_digit_only(self) -> None:
        self.assertEqual("555,625,570,650", MOUSE_COUNTER_ROI)

    def test_mouse_counter_roi_excludes_pointer_and_button(self) -> None:
        after = Path("after-mouse-click.ppm")
        before = Path("after-scroll.ppm")
        with patch("interaction_score_gate.pixel_diff",
                   return_value=(False, "counter text did not change")) as diff:
            passed, detail = mouse_counter_diff(after, before)

        self.assertFalse(passed)
        self.assertIn("counter text", detail)
        diff.assert_called_once_with(after, before, MOUSE_COUNTER_ROI, 20)

    def test_pointer_shape_in_old_sentence_roi_does_not_pass_counter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.ppm"
            after = Path(directory) / "after.ppm"
            self._write_ppm(before, set())
            pointer = {(x, y) for x in range(293, 301) for y in range(629, 644)}
            self._write_ppm(after, pointer)

            passed, _detail = mouse_counter_diff(after, before)

        self.assertFalse(passed)

    def test_digit_change_in_counter_roi_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.ppm"
            after = Path(directory) / "after.ppm"
            zero = ({(558, y) for y in range(631, 643)}
                    | {(564, y) for y in range(631, 643)}
                    | {(x, 631) for x in range(558, 565)}
                    | {(x, 642) for x in range(558, 565)})
            one = ({(561, y) for y in range(631, 643)}
                   | {(559, 633), (560, 632), (562, 642), (563, 642)})
            self._write_ppm(before, zero)
            self._write_ppm(after, one)

            passed, _detail = mouse_counter_diff(after, before)

        self.assertTrue(passed)


if __name__ == "__main__":
    unittest.main()
