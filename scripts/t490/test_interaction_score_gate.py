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
    def test_mouse_counter_roi_excludes_pointer_and_button(self) -> None:
        after = Path("after-mouse-click.ppm")
        before = Path("after-scroll.ppm")
        with patch("interaction_score_gate.pixel_diff",
                   return_value=(False, "counter text did not change")) as diff:
            passed, detail = mouse_counter_diff(after, before)

        self.assertFalse(passed)
        self.assertIn("counter text", detail)
        diff.assert_called_once_with(after, before, MOUSE_COUNTER_ROI, 20)


if __name__ == "__main__":
    unittest.main()
