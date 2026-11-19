#!/usr/bin/env python3
"""Regression tests for normalized score-gate result encodings."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from goal_audit import (
    audit_candidate_stability,
    audit_compatibility,
    gate_passes,
    input_gate_passes,
)


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


class CandidateStabilityAuditTests(unittest.TestCase):
    KERNEL_SHA = "ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2"

    def _run(self, root: Path, kernel_sha: str, result: str) -> Path:
        directory = root / "evidence" / "candidate-stability" / result
        directory.mkdir(parents=True)
        (directory / "build-manifest.txt").write_text(
            f"{kernel_sha}  /home/mo/xk6/candidate/target/kernel.bin\n",
            encoding="utf-8",
        )
        values = {
            "STABILITY_DRIVER_RC": "0",
            "STABILITY_ROUND_RC": "0",
            "STABILITY_NORMALIZER_RC": "0",
            "STABILITY_GATE_RC": "0" if result == "pass" else "1",
        }
        (directory / "stability-result.env").write_text(
            "".join(f"{key}={value}\n" for key, value in values.items()),
            encoding="utf-8",
        )
        (directory / "stability-gate.log").write_text(
            "STABILITY_GATE_PASS\n" if result == "pass" else "STABILITY_GATE_FAIL\n",
            encoding="utf-8",
        )
        return directory

    def test_candidate_hash_run_failure_is_not_overridden_by_old_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old_pass = self._run(root, "b" * 64, "pass")
            candidate_fail = self._run(root, self.KERNEL_SHA, "fail")
            result = audit_candidate_stability(root, self.KERNEL_SHA)

        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(len(result["runs"]), 1)
        self.assertEqual(result["runs"][0]["kernel_sha256"], self.KERNEL_SHA)
        self.assertEqual(result["runs"][0]["gate_rc"], "1")
        self.assertNotIn(str(old_pass.relative_to(root)), [row["evidence"] for row in result["runs"]])

    def test_candidate_hash_pass_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._run(root, self.KERNEL_SHA, "pass")
            result = audit_candidate_stability(root, self.KERNEL_SHA)

        self.assertEqual(result["status"], "PASS")

    def test_missing_matching_candidate_run_is_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._run(root, "b" * 64, "pass")
            result = audit_candidate_stability(root, self.KERNEL_SHA)

        self.assertEqual(result["status"], "INCOMPLETE")
        self.assertEqual(result["runs"], [])


if __name__ == "__main__":
    unittest.main()
