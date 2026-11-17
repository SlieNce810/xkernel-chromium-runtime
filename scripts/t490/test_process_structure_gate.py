#!/usr/bin/env python3
"""Regression checks for the rubric-scoped multiprocess structure gate."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import multiprocess_eventlog as eventlog


def make_event(
    *,
    timestamp: float,
    role: str,
    pid: int,
    ppid: int,
    name: str,
    observation_source: str | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "timestamp_monotonic": timestamp,
        "process_role": role,
        "pid": pid,
        "ppid": ppid,
        "navigation_id": 0,
        "frame_tree_node_id": 0,
        "document_id": "",
        "mojo_endpoint_or_pipe_id": "",
        "shared_object_id_or_file_object_id": "",
        "event": name,
        "status": "observed",
        "error": "",
    }
    if observation_source is not None:
        event["observation_source"] = observation_source
    return event


def direct_process_chain() -> list[dict[str, object]]:
    return [
        make_event(timestamp=1.0, role="browser", pid=70, ppid=5, name="browser-start"),
        make_event(
            timestamp=2.0,
            role="zygote",
            pid=272,
            ppid=70,
            name="zygote-observed",
            observation_source="guest-ps-snapshot",
        ),
        make_event(
            timestamp=3.0,
            role="renderer",
            pid=346,
            ppid=272,
            name="renderer-observed",
            observation_source="guest-ps-snapshot",
        ),
    ]


class ProcessStructureGateTests(unittest.TestCase):
    def test_verified_browser_zygote_renderer_chain_passes(self) -> None:
        summary = eventlog.summarize_process_structure(direct_process_chain(), [])

        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["score_points"], 4)
        self.assertTrue(summary["parent_links_verified"])

    def test_observed_roles_without_source_tag_are_rejected(self) -> None:
        events = direct_process_chain()
        events[1].pop("observation_source")
        events[2].pop("observation_source")

        summary = eventlog.summarize_process_structure(events, [])

        self.assertEqual(summary["result"], "FAIL")
        self.assertEqual(summary["score_points"], 0)
        self.assertEqual(summary["untrusted_observation_count"], 2)

    def test_renderer_without_zygote_parent_is_rejected(self) -> None:
        events = direct_process_chain()
        events[2]["ppid"] = 0

        summary = eventlog.summarize_process_structure(events, [])

        self.assertEqual(summary["result"], "FAIL")
        self.assertFalse(summary["parent_links_verified"])
        self.assertTrue(summary["parent_link_errors"])

    def test_process_events_do_not_pass_full_render_gate(self) -> None:
        summary = eventlog.summarize(direct_process_chain(), [])

        self.assertEqual(summary["result"], "FAIL")

    def test_single_process_command_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="process-score-command-") as temp_dir:
            command_file = Path(temp_dir) / "cmd.txt"
            command_file.write_text(
                "chromium --single-process file:///index.html\n", encoding="utf-8"
            )

            errors = eventlog._check_process_structure_command(command_file)

        self.assertEqual(len(errors), 1)
        self.assertIn("--single-process", errors[0])

    def test_guest_observer_does_not_filter_ps_through_awk(self) -> None:
        for observer_name in (
            "autorun_mp_score_observe3.sh",
            "autorun_mp_score_observe6.sh",
        ):
            with self.subTest(observer=observer_name):
                observer = Path(__file__).with_name(observer_name)
                source = observer.read_text(encoding="utf-8")

                self.assertIn('ps 2>/dev/null > "$PROCESS_LIST"', source)
                self.assertIn('observation_source":"%s"', source)
                self.assertIn('while read -r renderer_pid renderer_ppid', source)
                self.assertIn('[ "$renderer_parent_is_zygote" = "1" ] || continue', source)
                self.assertNotRegex(source, r"ps\s+2>/dev/null\s*\|\s*awk.*type=renderer")
                self.assertNotRegex(source, r"ps\s+2>/dev/null\s*\|\s*awk.*type=zygote")
                self.assertNotIn('case "$process_line" in *"--type=renderer"*)', source)


if __name__ == "__main__":
    unittest.main()
