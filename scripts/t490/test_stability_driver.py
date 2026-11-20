#!/usr/bin/env python3
"""Regression tests for stability driver console sample parsing."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stability_driver import parse_family_snapshot, parse_guest_clock_sync, wait_until_not_before


class StabilityDriverFamilyParsingTests(unittest.TestCase):
    def test_full_family_snapshot_parses_roles_and_member_states(self) -> None:
        line = (
            "\x1b[m[mpdiag] MP_FAMILY_WATCHDOG label=302775 n=3 "
            "70:browser/R/38 171:browser_child/S/1 301:zygote_child/S/8"
        )

        snapshot = parse_family_snapshot(line)

        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot["n"], 3)
        self.assertEqual(snapshot["roles"], ["browser", "browser_child", "zygote_child"])
        self.assertEqual(snapshot["members"][2]["pid"], 301)

    def test_family_count_marker_does_not_replace_latest_role_snapshot(self) -> None:
        self.assertIsNone(parse_family_snapshot("[mpdiag] MP_FAMILY_COUNT=18"))

    def test_non_watchdog_family_markers_are_not_stability_samples(self) -> None:
        self.assertIsNone(
            parse_family_snapshot(
                "[mpdiag] MP_FAMILY label=302775 n=3 "
                "70:browser/R/38 171:browser_child/S/1 301:zygote_child/S/8"
            )
        )

    def test_malformed_family_line_uses_observed_member_count(self) -> None:
        snapshot = parse_family_snapshot(
            "[mpdiag] MP_FAMILY_WATCHDOG label=123 70:browser/R/38 171:browser_child/S/1"
        )

        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot["n"], 2)


class StabilityReloadSettleTests(unittest.TestCase):
    def test_screendump_barrier_waits_and_keeps_heartbeat_alive(self) -> None:
        now = [0.0]
        sleeps: list[float] = []
        heartbeats: list[float] = []

        def monotonic() -> float:
            return now[0]

        def sleeper(duration: float) -> None:
            sleeps.append(duration)
            now[0] += duration

        def heartbeat() -> None:
            heartbeats.append(now[0])

        wait_until_not_before(2.5, heartbeat, 1.0, monotonic, sleeper)

        self.assertEqual(now[0], 2.5)
        self.assertEqual(sleeps, [1.0, 1.0, 0.5])
        self.assertEqual(heartbeats, [0.0, 1.0, 2.0])

    def test_screendump_barrier_does_not_wait_after_deadline(self) -> None:
        calls: list[str] = []
        wait_until_not_before(1.0, lambda: calls.append("heartbeat"), 1.0,
                              lambda: 1.0, lambda _: calls.append("sleep"))
        self.assertEqual(calls, [])


class StabilityGuestClockSyncTests(unittest.TestCase):
    def test_clock_sync_marker_matches_run_and_reads_monotonic_ns(self) -> None:
        line = "\x1b[mMP_METRICS_CLOCK_SYNC run_id=run-12 guest_t_ns=1234567890123"
        self.assertEqual(1234567890123, parse_guest_clock_sync(line, "run-12"))

    def test_clock_sync_marker_from_another_run_is_ignored(self) -> None:
        line = "MP_METRICS_CLOCK_SYNC run_id=run-other guest_t_ns=123456"
        self.assertIsNone(parse_guest_clock_sync(line, "run-12"))

    def test_malformed_clock_sync_marker_is_ignored(self) -> None:
        line = "MP_METRICS_CLOCK_SYNC run_id=run-12 guest_t_ns=not-a-number"
        self.assertIsNone(parse_guest_clock_sync(line, "run-12"))


if __name__ == "__main__":
    unittest.main()
