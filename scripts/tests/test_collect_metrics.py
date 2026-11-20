from __future__ import annotations

import csv
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collect_metrics  # noqa: E402


RUN_ID = "metrics-fixture-01"
SECOND = 1_000_000_000


def event(seq: int, t_ns: int, name: str, **fields: object) -> dict[str, object]:
    return {
        "schema": collect_metrics.EVENT_SCHEMA,
        "run_id": RUN_ID,
        "clock_id": "guest-CLOCK_MONOTONIC",
        "seq": seq,
        "event_id": f"event-{seq}",
        "t_ns": t_ns,
        "event": name,
        **fields,
    }


def fixture(root: Path) -> tuple[Path, Path, list[dict[str, object]], Path]:
    root.mkdir(parents=True, exist_ok=True)
    image = root / "screenshots" / "frame-0001.ppm"
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(b"P6\n1 1\n255\n\x20\x40\x60")
    image_sha = hashlib.sha256(image.read_bytes()).hexdigest()
    events = [
        event(1, 0, "browser_launch_requested", launch_id="launch-01"),
        event(2, 1, "process_started", pid=100, ppid=1, process_instance="browser-1", parent_process_instance=None, role="browser"),
        event(3, 500_000_000, "browser_main_loop_ready", pid=100, process_instance="browser-1"),
        event(4, 600_000_000, "navigation_requested", navigation_id="nav-01", url="file:///index.html"),
        event(5, 650_000_000, "process_started", pid=101, ppid=100, process_instance="zygote-1", parent_process_instance="browser-1", role="zygote"),
        event(6, 700_000_000, "renderer_create_requested", request_id="renderer-request-01", navigation_id="nav-01", browser_pid=100),
        event(7, 710_000_000, "process_started", pid=102, ppid=101, process_instance="renderer-1", parent_process_instance="zygote-1", role="renderer"),
        event(8, SECOND, "renderer_ready", request_id="renderer-request-01", navigation_id="nav-01", renderer_id="renderer-id-01", pid=102, process_instance="renderer-1"),
        event(9, 2 * SECOND, "first_valid_frame", navigation_id="nav-01", renderer_id="renderer-id-01", pid=102, process_instance="renderer-1", valid=True, source="wayland-commit"),
        event(10, 2_500_000_000, "page_verdict", navigation_id="nav-01", renderer_id="renderer-id-01", **{"pass": True, "strict": True, "profile": "official-index"}),
        event(11, 3 * SECOND, "screendump_verified", navigation_id="nav-01", renderer_id="renderer-id-01", **{"pass": True, "profile": "official-index"}, capture_path="screenshots/frame-0001.ppm", sha256=image_sha, sampling_interval_ms=1000),
    ]
    event_path = root / "lifecycle-events.jsonl"
    event_path.write_text("".join(json.dumps(row) + "\n" for row in events), encoding="utf-8")
    memory_path = root / "memory-samples.csv"
    columns = ["run_id", "clock_id", "sample_id", "t_ns", "pid", "ppid", "process_instance", "rss_kb", "pss_kb", "uss_kb"]
    with memory_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for second in range(63):
            t_ns = 1_100_000_000 + second * SECOND
            for pid, ppid, instance, rss, pss, uss in (
                (100, 1, "browser-1", 10000, 8000, 6000),
                (101, 100, "zygote-1", 5000, 3000, 1000),
                (102, 101, "renderer-1", 9000, 7000, 5000),
            ):
                writer.writerow({
                    "run_id": RUN_ID,
                    "clock_id": "guest-CLOCK_MONOTONIC",
                    "sample_id": f"sample-{second:03d}",
                    "t_ns": t_ns,
                    "pid": pid,
                    "ppid": ppid,
                    "process_instance": instance,
                    "rss_kb": rss + second,
                    "pss_kb": pss + second,
                    "uss_kb": uss + second,
                })
    return event_path, memory_path, events, image


class CollectMetricsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.evidence = Path(self.temp.name) / "run"
        self.events, self.memory, self.rows, self.image = fixture(self.evidence)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def validate(self) -> list[dict[str, str]]:
        with patch("collect_metrics.subprocess.run") as run:
            run.return_value.returncode = 0
            return collect_metrics.validate_sample(
                self.evidence, RUN_ID, "official-index", self.events, self.memory
            )

    def save_events(self, rows: list[dict[str, object]]) -> None:
        self.events.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def test_valid_sample_emits_all_required_metrics_and_memory_peaks(self) -> None:
        rows = self.validate()
        values = {row["metric"]: float(row["value"]) for row in rows}
        self.assertEqual(500.0, values["browser_startup_ms"])
        self.assertEqual(300.0, values["renderer_create_ms"])
        self.assertEqual(1400.0, values["page_first_frame_ms"])
        self.assertTrue(collect_metrics.REQUIRED_METRICS.issubset(values))
        self.assertEqual(62, values["memory_sample_count"])
        self.assertGreater(values["peak_chromium_rss_kb"], 24000)
        self.assertGreater(values["peak_chromium_pss_kb"], 18000)
        self.assertGreater(values["peak_chromium_uss_kb"], 12000)

    def test_strict_screendump_can_precede_its_page_verdict(self) -> None:
        rows = [dict(row) for row in self.rows]
        rows[9]["t_ns"] = 2_500_000_000  # page_verdict
        rows[10]["t_ns"] = 2_400_000_000  # screenshot was captured and checked first
        rows.sort(key=lambda row: int(row["t_ns"]))
        for seq, row in enumerate(rows, 1):
            row["seq"] = seq
            row["event_id"] = f"event-{seq}"
        self.save_events(rows)

        values = {row["metric"]: float(row["value"]) for row in self.validate()}

        self.assertEqual(1800.0, values["page_first_screendump_upper_bound_ms"])

    def test_post_window_samples_do_not_inflate_peak(self) -> None:
        with self.memory.open(encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream))
        for row in rows:
            if row["sample_id"] == "sample-062":
                row["rss_kb"] = row["pss_kb"] = row["uss_kb"] = "999999"
        with self.memory.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)

        values = {row["metric"]: float(row["value"]) for row in self.validate()}

        self.assertEqual(62, values["memory_sample_count"])
        self.assertEqual(24183, values["peak_chromium_rss_kb"])
        self.assertEqual(18183, values["peak_chromium_pss_kb"])
        self.assertEqual(12183, values["peak_chromium_uss_kb"])

    def test_missing_frame_event_is_rejected(self) -> None:
        self.save_events([row for row in self.rows if row["event"] != "first_valid_frame"])
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "first_valid_frame"):
            self.validate()

    def test_out_of_order_event_time_is_rejected(self) -> None:
        rows = [dict(row) for row in self.rows]
        rows[5]["t_ns"] = 1
        self.save_events(rows)
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "moved backwards"):
            self.validate()

    def test_pid_reuse_without_exit_is_rejected(self) -> None:
        rows = [dict(row) for row in self.rows]
        rows.append(event(12, 2_200_000_000, "process_started", pid=102, ppid=101, process_instance="renderer-reused", parent_process_instance="zygote-1", role="renderer"))
        rows.sort(key=lambda row: int(row["t_ns"]))
        for seq, row in enumerate(rows, 1):
            row["seq"] = seq
            row["event_id"] = f"event-{seq}"
        self.save_events(rows)
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "PID reuse"):
            self.validate()

    def test_navigation_mismatch_is_rejected(self) -> None:
        rows = [dict(row) for row in self.rows]
        rows[8]["navigation_id"] = "nav-other"
        self.save_events(rows)
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "first_valid_frame"):
            self.validate()

    def test_duplicate_sample_id_at_another_time_is_rejected(self) -> None:
        with self.memory.open(encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream))
        for row in rows:
            if row["sample_id"] == "sample-001":
                row["sample_id"] = "sample-000"
                break
        with self.memory.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "duplicate memory row|multiple timestamps|share one timestamp"):
            self.validate()

    def test_empty_memory_csv_is_rejected(self) -> None:
        self.memory.write_text("run_id,clock_id,sample_id,t_ns,pid,ppid,process_instance,rss_kb,pss_kb,uss_kb\n", encoding="utf-8")
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "empty"):
            self.validate()

    def test_zero_memory_is_rejected_as_unavailable(self) -> None:
        with self.memory.open(encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream))
        for row in rows:
            row["rss_kb"] = row["pss_kb"] = row["uss_kb"] = "0"
        with self.memory.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "zero/unavailable"):
            self.validate()

    def test_duplicate_run_in_existing_csv_is_rejected(self) -> None:
        output = Path(self.temp.name) / "raw.csv"
        output.write_text("metric,run,value,unit,evidence\nbrowser_startup_ms,metrics-fixture-01,1,ms,evidence\n", encoding="utf-8")
        with self.assertRaisesRegex(collect_metrics.InvalidSample, "duplicate run identifier"):
            collect_metrics.check_duplicate_run(output, RUN_ID)


if __name__ == "__main__":
    unittest.main()
