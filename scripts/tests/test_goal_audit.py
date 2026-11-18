#!/usr/bin/env python3
"""Regression tests for normalized score-gate result encodings."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from goal_audit import gate_passes, input_gate_passes


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


if __name__ == "__main__":
    unittest.main()
