#!/usr/bin/env python3
"""Regression tests for stability liveness snapshots."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from normalize_stability_events import normalize_rows


def event(seq: int, t_ns: int, name: str, **fields: object) -> dict[str, object]:
    return {
        "schema": "xkernel.stability.v1",
        "run_id": "r2",
        "clock_id": "t490-host-CLOCK_MONOTONIC",
        "event_id": f"r2:{seq}",
        "seq": seq,
        "t_ns": t_ns,
        "event": name,
        **fields,
    }


def family_snapshot(seq: int, t_ns: int) -> dict[str, object]:
    return event(
        seq,
        t_ns,
        "guest_process_snapshot",
        n=3,
        roles=["browser", "browser_child", "zygote_child"],
        members=[
            {"pid": 70, "kind": "browser", "state": "S", "threads": 38},
            {"pid": 171, "kind": "browser_child", "state": "S", "threads": 1},
            {"pid": 295, "kind": "zygote_child", "state": "S", "threads": 7},
        ],
    )


class NormalizeStabilityEventTests(unittest.TestCase):
    def test_empty_count_marker_is_repaired_from_fresh_family_snapshot(self) -> None:
        rows = [
            family_snapshot(1, 10_000_000_000),
            event(2, 20_000_000_000, "guest_process_snapshot", n=0, roles=[], members=[]),
            event(
                3,
                22_000_000_000,
                "host_liveness",
                guest_watchdog={"weston": "yes", "chrome": "yes"},
                guest_family={"n": 0, "roles": [], "members": []},
                guest_family_age_s=1.0,
            ),
        ]

        normalized, summary = normalize_rows(rows)

        liveness = normalized[-1]
        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["repaired_liveness_count"], 1)
        self.assertEqual(
            liveness["guest_family"]["roles"],
            ["browser", "browser_child", "zygote_child"],
        )
        self.assertAlmostEqual(liveness["guest_family_age_s"], 12.0)
        self.assertTrue(liveness["family_normalized"])
        self.assertEqual(rows[-1]["guest_family"]["roles"], [])

    def test_stale_family_snapshot_is_not_reused(self) -> None:
        rows = [
            family_snapshot(1, 10_000_000_000),
            event(
                2,
                50_000_000_000,
                "host_liveness",
                guest_watchdog={"weston": "yes", "chrome": "yes"},
                guest_family={"n": 0, "roles": [], "members": []},
                guest_family_age_s=1.0,
            ),
        ]

        normalized, summary = normalize_rows(rows)

        self.assertEqual(summary["result"], "FAIL")
        self.assertIn("no fresh non-empty", summary["errors"][0])
        self.assertEqual(normalized[-1]["guest_family"]["roles"], [])

    def test_valid_fresh_family_is_preserved(self) -> None:
        family = {
            "n": 3,
            "roles": ["browser", "browser_child", "zygote_child"],
            "members": [{"pid": 70, "kind": "browser", "state": "S", "threads": 38}],
        }
        rows = [
            family_snapshot(1, 10_000_000_000),
            event(
                2,
                12_000_000_000,
                "host_liveness",
                guest_watchdog={"weston": "yes", "chrome": "yes"},
                guest_family=family,
                guest_family_age_s=2.0,
            ),
        ]

        normalized, summary = normalize_rows(rows)

        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["repaired_liveness_count"], 0)
        self.assertEqual(normalized[-1]["guest_family"], family)


if __name__ == "__main__":
    unittest.main()
