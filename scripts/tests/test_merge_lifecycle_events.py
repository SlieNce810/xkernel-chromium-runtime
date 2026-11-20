from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t490"))
import merge_lifecycle_events  # noqa: E402


RUN_ID = "lifecycle-merge-test-01"
NAV_ID = "nav-00"
SCHEMA = "xkernel.browser.lifecycle.v1"


def guest_event(seq: int, t_ns: int, name: str, **fields: object) -> dict[str, object]:
    return {
        "schema": SCHEMA,
        "run_id": RUN_ID,
        "clock_id": "LINUX_CLOCK_MONOTONIC",
        "seq": seq,
        "event_id": f"memory:{seq}",
        "t_ns": t_ns,
        "event": name,
        **fields,
    }


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def fixture(root: Path, *, frame_event: bool = True, screenshot_present: bool = True):
    root.mkdir(parents=True, exist_ok=True)
    evidence = root / "evidence"
    screenshot = evidence / "stability" / "load-00-initial.ppm"
    screenshot.parent.mkdir(parents=True, exist_ok=True)
    if screenshot_present:
        screenshot.write_bytes(b"P6\n1 1\n255\n\x20\x40\x60")
    memory_path = root / "memory-events.jsonl"
    write_jsonl(memory_path, [
        guest_event(1, 100, "browser_launch_requested"),
        guest_event(2, 200, "process_started", pid=10, ppid=1,
                    process_instance="10-1", role="browser", parent_process_instance=None),
        guest_event(3, 220, "process_started", pid=11, ppid=10,
                    process_instance="11-2", role="zygote", parent_process_instance="10-1"),
        guest_event(4, 400, "process_started", pid=12, ppid=11,
                    process_instance="12-3", role="renderer", parent_process_instance="11-2"),
        guest_event(5, 900, "memory_sampling_finished"),
    ])
    probe_path = root / "lifecycle-probe-events.jsonl"
    probe_rows = [
        guest_event(1, 250, "browser_main_loop_ready", pid=10,
                    process_instance="10-1", role="browser"),
        guest_event(2, 300, "navigation_requested", pid=10,
                    process_instance="10-1", role="browser", navigation_id=NAV_ID,
                    url="file:///usr/share/html-test/index.html", source="browser-file-url-open"),
        guest_event(3, 350, "renderer_create_requested", pid=11,
                    process_instance="11-2", role="zygote", navigation_id=NAV_ID,
                    request_id="request-01", child_pid=12),
        guest_event(4, 450, "renderer_ready", pid=12,
                    process_instance="12-3", role="renderer", navigation_id=NAV_ID,
                    request_id="request-01", renderer_id="12-3"),
    ]
    if frame_event:
        probe_rows.append(guest_event(5, 600, "first_valid_frame", pid=12,
                                      process_instance="12-3", role="renderer",
                                      navigation_id=NAV_ID, renderer_id="12-3",
                                      source="wayland-buffer-commit", valid=True))
    write_jsonl(probe_path, probe_rows)
    stability_path = root / "stability-events.jsonl"
    stability_rows = [
        {"schema": "xkernel.stability.v1", "run_id": RUN_ID,
         "clock_id": "t490-host-CLOCK_MONOTONIC", "event": "clock_sync",
         "host_receive_t_ns": 1000, "guest_clock_id": "LINUX_CLOCK_MONOTONIC",
         "guest_t_ns": 500},
        {"schema": "xkernel.stability.v1", "run_id": RUN_ID,
         "clock_id": "t490-host-CLOCK_MONOTONIC", "event": "page_ready",
         "t_ns": 1600, "navigation_id": NAV_ID, "pass_result": True,
         "profile": "official-index", "capture_path": "stability/load-00-initial.ppm"},
        {"schema": "xkernel.stability.v1", "run_id": RUN_ID,
         "clock_id": "t490-host-CLOCK_MONOTONIC", "event": "screendump_verified",
         "t_ns": 1700, "navigation_id": NAV_ID, "pass_result": True,
         "profile": "official-index", "capture_path": "stability/load-00-initial.ppm"},
        {"schema": "xkernel.stability.v1", "run_id": RUN_ID,
         "clock_id": "t490-host-CLOCK_MONOTONIC", "event": "clock_sync",
         "host_receive_t_ns": 2000, "guest_clock_id": "LINUX_CLOCK_MONOTONIC",
         "guest_t_ns": 1500},
    ]
    write_jsonl(stability_path, stability_rows)
    return evidence, memory_path, probe_path, stability_path


class MergeLifecycleEventsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.evidence, self.memory, self.probe, self.stability = fixture(self.root)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_merge(self, *, evidence: Path | None = None, probe: Path | None = None):
        out = self.root / "merged.jsonl"
        summary = self.root / "merge-summary.json"
        result = merge_lifecycle_events.merge(
            self.memory, probe or self.probe, self.stability, evidence or self.evidence,
            out, summary, RUN_ID, NAV_ID, 30000,
        )
        return result, out

    def test_merges_guest_events_and_mapped_qmp_verdicts(self) -> None:
        summary, out = self.run_merge()
        rows = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines()]
        self.assertTrue(summary["valid"])
        self.assertEqual(list(range(1, len(rows) + 1)), [row["seq"] for row in rows])
        page = next(row for row in rows if row["event"] == "page_verdict")
        shot = next(row for row in rows if row["event"] == "screendump_verified")
        self.assertEqual(1100, page["t_ns"])
        self.assertEqual(1200, shot["t_ns"])
        self.assertEqual("12-3", page["renderer_id"])
        self.assertTrue(shot["sha256"])

    def test_missing_frame_is_preserved_and_reported_invalid(self) -> None:
        _evidence, _memory, probe, _stability = fixture(self.root / "missing-frame", frame_event=False)
        summary, _out = self.run_merge(evidence=_evidence, probe=probe)
        self.assertFalse(summary["valid"])
        self.assertIn("expected one first_valid_frame", " ".join(summary["errors"]))

    def test_host_verdict_outside_clock_sync_range_is_rejected(self) -> None:
        rows = [json.loads(line) for line in self.stability.read_text(encoding="utf-8").splitlines()]
        for row in rows:
            if row["event"] == "page_ready":
                row["t_ns"] = 2500
        write_jsonl(self.stability, rows)
        with self.assertRaisesRegex(merge_lifecycle_events.MergeError, "outside guest clock-sync anchors"):
            self.run_merge()


if __name__ == "__main__":
    unittest.main()
