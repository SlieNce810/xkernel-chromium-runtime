#!/usr/bin/env python3
"""Regression tests for normalized score-gate result encodings."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from goal_audit import audit_compatibility, gate_passes, input_gate_passes


class GatePassTests(unittest.TestCase):
    def _gate(self, value: object) -> bool:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gate.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return gate_passes(path)

    def test_boolean_pass_is_accepted(self) -> None:
        self.assertTrue(self._gate({"pass": True}))

    def test_numeric_one_pass_is_accepted(self) -> None:
        self.assertTrue(self._gate({"pass": 1}))

    def test_numeric_zero_is_rejected(self) -> None:
        self.assertFalse(self._gate({"pass": 0}))

    def test_false_boolean_is_rejected(self) -> None:
        self.assertFalse(self._gate({"pass": False}))

    def test_pass_result_string_is_accepted(self) -> None:
        self.assertTrue(self._gate({"result": "PASS"}))

    def _input_gate(self, value: object) -> bool:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input-gate.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return input_gate_passes(path)

    def test_keyboard_only_gate_does_not_award_pointer_input_points(self) -> None:
        self.assertFalse(self._input_gate({"input_mode": "kbd", "pass": 1}))

    def test_pointer_gate_requires_all_interaction_subgates(self) -> None:
        self.assertTrue(self._input_gate({
            "input_mode": "pointer", "interaction_score_gate_rc": 0, "pass": 1,
        }))
        self.assertFalse(self._input_gate({
            "input_mode": "pointer", "interaction_score_gate_rc": 1, "pass": 0,
        }))


class CompatibilityAuditTests(unittest.TestCase):
    def _write_summary(self, root: Path, payload: dict[str, object]) -> Path:
        path = root / "compatibility-final" / "summary.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_missing_compatibility_summary_keeps_legacy_pending_items(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = audit_compatibility(Path(directory) / "evidence")

        self.assertEqual(result["status"], "INCOMPLETE")
        self.assertIn("timerfd frozen-version probe and regression", result["pending"])

    def test_incomplete_summary_preserves_reviewed_completed_and_pending_items(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence"
            self._write_summary(evidence, {
                "schema": "xkernel.compatibility-final.v1",
                "result": "INCOMPLETE",
                "completed": ["SCM_RIGHTS short-read: PASS"],
                "pending": ["inotify watch target path attribution"],
            })
            result = audit_compatibility(evidence)

        self.assertEqual(result["status"], "INCOMPLETE")
        self.assertEqual(result["completed"], ["SCM_RIGHTS short-read: PASS"])
        self.assertEqual(result["pending"], ["inotify watch target path attribution"])

    def test_pass_requires_pass_result_and_no_pending_items(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence"
            self._write_summary(evidence, {
                "schema": "xkernel.compatibility-final.v1",
                "result": "PASS",
                "completed": ["all matrix rows validated"],
                "pending": [],
            })
            result = audit_compatibility(evidence)

        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["pending"], [])


if __name__ == "__main__":
    unittest.main()
