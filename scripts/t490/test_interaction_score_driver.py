#!/usr/bin/env python3
"""Tests for real relative-pointer movement sequencing."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from interaction_score_driver import click_step, pointer_targets


class RecordingClient:
    def __init__(self) -> None:
        self.moves: list[tuple[str, int]] = []
        self.clicks = 0
        self.records: list[tuple[str, dict[str, object]]] = []

    def relative(self, axis: str, value: int) -> None:
        self.moves.append((axis, value))

    def click(self) -> None:
        self.clicks += 1

    def _record(self, kind: str, value: dict[str, object]) -> None:
        self.records.append((kind, value))


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
    def test_step3_counter_target_compensates_observed_offset(self) -> None:
        self.assertEqual(((250, 588), (350, 710)), pointer_targets("step3"))

    def test_step1_and_step4_keep_separate_calibrations(self) -> None:
        self.assertEqual(((281, 674), (350, 710)), pointer_targets("step1"))
        self.assertEqual(((247, 607), (292, 638)), pointer_targets("step4"))


if __name__ == "__main__":
    unittest.main()
