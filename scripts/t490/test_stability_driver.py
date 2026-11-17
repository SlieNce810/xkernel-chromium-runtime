#!/usr/bin/env python3
"""Regression tests for stability driver console sample parsing."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stability_driver import parse_family_snapshot


class StabilityDriverFamilyParsingTests(unittest.TestCase):
    def test_full_family_snapshot_parses_roles_and_member_states(self) -> None:
        line = (
            "\x1b[m[mpdiag] MP_FAMILY label=302775 n=3 "
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

    def test_malformed_family_line_uses_observed_member_count(self) -> None:
        snapshot = parse_family_snapshot(
            "[mpdiag] MP_FAMILY label=123 70:browser/R/38 171:browser_child/S/1"
        )

        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot["n"], 2)


if __name__ == "__main__":
    unittest.main()
