from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t490"))
import extract_lifecycle_probe_events as extractor  # noqa: E402


RUN_ID = "lifecycle-fixture-01"


def marker(export_seq: int, seq: int, t_ns: int, event: str) -> str:
    row = {
        "schema": extractor.EVENT_SCHEMA,
        "run_id": RUN_ID,
        "clock_id": extractor.CLOCK_ID,
        "seq": seq,
        "t_ns": t_ns,
        "event_id": f"event-{seq}",
        "event": event,
        "pid": 70,
    }
    return f"\x1b[37m[guest] MP_LIFECYCLE_PROBE_EVENT run_id={RUN_ID} seq={export_seq} {json.dumps(row)}\r\n"


class ExtractLifecycleProbeTests(unittest.TestCase):
    def write_console(self, text: str) -> Path:
        path = Path(self.temp.name) / "console.log"
        path.write_text(text, encoding="utf-8")
        return path

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_extracts_ansi_prefixed_events(self) -> None:
        path = self.write_console(marker(0, 10, 100, "preload_attached") + marker(1, 20, 200, "browser_main_loop_ready"))
        rows, summary = extractor.extract(path, RUN_ID)
        self.assertEqual(2, len(rows))
        self.assertEqual(10, summary["first_seq"])
        self.assertTrue(summary["export_sequence_contiguous"])

    def test_rejects_run_mismatch(self) -> None:
        path = self.write_console(marker(0, 1, 100, "preload_attached").replace(RUN_ID, "other-run"))
        with self.assertRaisesRegex(extractor.LifecycleExtractionError, "does not match"):
            extractor.extract(path, RUN_ID)

    def test_rejects_duplicate_event_id(self) -> None:
        first = marker(0, 1, 100, "preload_attached")
        second = marker(1, 1, 200, "browser_main_loop_ready")
        path = self.write_console(first + second)
        with self.assertRaisesRegex(extractor.LifecycleExtractionError, "duplicate event_id"):
            extractor.extract(path, RUN_ID)

    def test_rejects_export_gap_by_default(self) -> None:
        path = self.write_console(marker(0, 1, 100, "preload_attached") + marker(2, 2, 200, "browser_main_loop_ready"))
        with self.assertRaisesRegex(extractor.LifecycleExtractionError, "not contiguous"):
            extractor.extract(path, RUN_ID)
        rows, _ = extractor.extract(path, RUN_ID, allow_export_gaps=True)
        self.assertEqual(2, len(rows))


if __name__ == "__main__":
    unittest.main()
