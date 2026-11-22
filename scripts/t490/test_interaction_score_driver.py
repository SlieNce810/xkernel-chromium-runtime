#!/usr/bin/env python3
"""Tests for real relative-pointer movement sequencing."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from interaction_score_driver import (
    click_counter_with_retries,
    click_step,
    counter_retry_targets_from_env,
    pointer_targets_from_env,
)


class RecordingClient:
    def __init__(self) -> None:
        self.moves: list[tuple[str, int]] = []
        self.clicks = 0
        self.records: list[tuple[str, dict[str, object]]] = []
        self.shots = 0

    def relative(self, axis: str, value: int) -> None:
        self.moves.append((axis, value))

    def click(self) -> None:
        self.clicks += 1

    def _record(self, kind: str, value: dict[str, object]) -> None:
        self.records.append((kind, value))

    def screendump(self, path: Path) -> None:
        self.shots += 1
        path.write_text(f"screenshot-{self.shots}", encoding="utf-8")


class ClickStepTests(unittest.TestCase):
    def test_step1_emits_one_pixel_relative_events_and_real_clicks(self) -> None:
        client = RecordingClient()
        with patch("interaction_score_driver.time.sleep") as sleep:
            click_step(client, 3, 2, "test-target", count=2,
                       step_size=1, step_delay=0.05)  # type: ignore[arg-type]

        self.assertEqual(
            [
                ("x", -2000), ("y", -2000),
                ("x", 1), ("x", 1), ("x", 1),
                ("y", 1), ("y", 1),
            ],
            client.moves,
        )
        self.assertEqual(2, client.clicks)
        self.assertEqual(6, sleep.call_count)
        self.assertEqual("step1", client.records[0][1]["pointer_mode"])

    def test_step3_emits_three_pixel_relative_events(self) -> None:
        client = RecordingClient()
        with patch("interaction_score_driver.time.sleep") as sleep:
            click_step(client, 7, 5, "test-target", count=1,
                       step_size=3, step_delay=0.02)  # type: ignore[arg-type]

        self.assertEqual(
            [("x", -2000), ("y", -2000), ("x", 3), ("x", 3), ("x", 1),
             ("y", 3), ("y", 2)],
            client.moves,
        )
        self.assertEqual(1, client.clicks)
        self.assertEqual(5, sleep.call_count)
        self.assertEqual("step3", client.records[0][1]["pointer_mode"])


class PointerTargetTests(unittest.TestCase):
    def test_step3_keeps_last_in_frame_candidate_after_extrapolation_failed(self) -> None:
        self.assertEqual(((250, 588), (350, 710)),
                         pointer_targets_from_env("step3", {}))

    def test_per_run_targets_override_without_editing_driver(self) -> None:
        self.assertEqual(((280, 675), (350, 710)), pointer_targets_from_env(
            "step3", {"INTERACTION_COUNTER_TARGET": "280,675",
                      "INTERACTION_NAV_TARGET": "350,710"}))

    def test_invalid_target_is_rejected(self) -> None:
        for value in ("1", "x,2", "-1,2", "2,4097"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                pointer_targets_from_env(
                    "step3", {"INTERACTION_COUNTER_TARGET": value})

    def test_counter_retry_targets_are_ordered_and_validated(self) -> None:
        self.assertEqual(((350, 710), (150, 522)),
                         counter_retry_targets_from_env(
                             {"INTERACTION_COUNTER_RETRY_TARGETS":
                              "350,710; 150,522"}))
        with self.assertRaises(ValueError):
            counter_retry_targets_from_env(
                {"INTERACTION_COUNTER_RETRY_TARGETS": "1,2;bad"})

    def test_counter_click_stops_on_first_screenshot_roi_pass(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = RecordingClient()
            attempted: list[tuple[int, int]] = []

            def record_click(x, y, _label, count=1):
                self.assertEqual(2, count)
                attempted.append((x, y))

            with patch("interaction_score_driver.mouse_counter_diff",
                          side_effect=[(False, "no counter change"),
                                       (True, "counter changed")]), \
                    patch("interaction_score_driver.time.sleep"):
                passed, attempts = click_counter_with_retries(
                    client, pointer_click=record_click,
                    initial_target=(250, 540),
                    retry_targets=((350, 710),), baseline=root / "baseline.ppm",
                    after_path=root / "after-mouse-click.ppm", shot_dir=root,
                    )

            self.assertTrue(passed)
            self.assertEqual(2, attempts)
            self.assertEqual([(250, 540), (350, 710)], attempted)
            self.assertEqual("screenshot-2",
                             (root / "after-mouse-click.ppm").read_text(encoding="utf-8"))
            self.assertTrue((root / "counter-attempt-1.ppm").is_file())
            self.assertFalse((root / "counter-attempt-2.ppm").exists())
            self.assertEqual("mouse-counter-attempt", client.records[-1][1]["name"])
            self.assertEqual(2, client.records[-1][1]["attempt"])

    def test_step1_and_step4_keep_separate_calibrations(self) -> None:
        self.assertEqual(((281, 674), (350, 710)),
                         pointer_targets_from_env("step1", {}))
        self.assertEqual(((247, 607), (292, 638)),
                         pointer_targets_from_env("step4", {}))


if __name__ == "__main__":
    unittest.main()
