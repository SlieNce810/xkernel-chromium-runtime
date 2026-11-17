#!/usr/bin/env python3
"""Regression tests for truncated guest process events in console logs."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import multiprocess_eventlog
from t490.normalize_process_eventlog import normalize_console_text


def full_event(
    timestamp: float, role: str, pid: int, ppid: int, event: str, source: str
) -> str:
    return json.dumps(
        {
            "timestamp_monotonic": timestamp,
            "process_role": role,
            "pid": pid,
            "ppid": ppid,
            "navigation_id": 0,
            "frame_tree_node_id": 0,
            "document_id": "",
            "mojo_endpoint_or_pipe_id": "",
            "shared_object_id_or_file_object_id": "",
            "event": event,
            "status": "observed",
            "error": "",
            "observation_source": source,
        },
        separators=(",", ":"),
    )


class NormalizeProcessEventLogTests(unittest.TestCase):
    def test_truncated_browser_prefix_is_joined_to_matching_process_observation(self) -> None:
        console = "\r\n".join(
            [
                '\x1b[mMP_EVENT {"timestamp_monotonic":39.864000,"process_role":"browser","pid":66,"ppid":5\r\r',
                "[mpdiag] MP_PROCESS_OBSERVED role=browser event=browser-start pid=66 ppid=5",
                "MP_EVENT " + full_event(
                    70.0, "zygote", 159, 66, "zygote-observed", "guest-ps-snapshot"
                ),
                "MP_EVENT " + full_event(
                    71.391001, "zygote", 160, 66, "zygote-observed", "guest-ps-snapshot"
                ),
                "[mpdiag] MP_PROCESS_OBSERVED role=zygote event=zygote-observed pid=160 ppid=66",
                "MP_EVENT " + full_event(
                    193.072006, "renderer", 282, 160, "renderer-observed", "guest-ps-snapshot"
                ),
                "[mpdiag] MP_PROCESS_OBSERVED role=renderer event=renderer-observed pid=282 ppid=160",
            ]
        )

        events, summary = normalize_console_text(console)
        gate = multiprocess_eventlog.summarize_process_structure(events, [])

        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["reconstructed_count"], 1)
        self.assertEqual(gate["result"], "PASS")
        self.assertTrue(gate["parent_links_verified"])
        self.assertEqual(gate["parent_link_errors"], [])
        self.assertTrue(gate["alternate_parent_link_mismatches"])
        self.assertTrue(events[0]["console_reconstructed"])

    def test_truncated_event_without_matching_observation_is_rejected(self) -> None:
        console = (
            'MP_EVENT {"timestamp_monotonic":39.864000,"process_role":"browser",'
            '"pid":66,"ppid":5\r\r\n'
        )

        events, summary = normalize_console_text(console)

        self.assertEqual(events, [])
        self.assertEqual(summary["result"], "FAIL")
        self.assertIn("expected one matching MP_PROCESS_OBSERVED", summary["errors"][0])

    def test_mismatched_parent_is_not_joined(self) -> None:
        console = "\n".join(
            [
                'MP_EVENT {"timestamp_monotonic":39.864000,"process_role":"browser","pid":66,"ppid":5',
                "[mpdiag] MP_PROCESS_OBSERVED role=browser event=browser-start pid=66 ppid=6",
            ]
        )

        events, summary = normalize_console_text(console)

        self.assertEqual(events, [])
        self.assertEqual(summary["result"], "FAIL")

    def test_complete_process_events_are_preserved_without_reconstruction(self) -> None:
        event = json.loads(
            full_event(3.0, "browser", 70, 5, "browser-start", "guest-launcher")
        )
        events, summary = normalize_console_text("MP_EVENT " + json.dumps(event))

        self.assertEqual(events, [event])
        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["reconstructed_count"], 0)


if __name__ == "__main__":
    unittest.main()
