from __future__ import annotations

import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_perf  # noqa: E402


CONDITIONS = {
    "host": "mo-ThinkPad-T490",
    "host_cpu": "Intel Core i7-8665U",
    "host_memory_gib": 14.7,
    "host_os": "Ubuntu 26.04.1 LTS",
    "qemu_version": "10.2.1",
    "guest_arch": "aarch64",
    "guest_memory_gib": 2,
    "qemu_accel": "pure-tcg",
    "chromium_version": "149.0.7827.53",
    "chromium_sha256": "chromium-hash",
    "rootfs_sha256": "rootfs-hash",
    "overlay_sha256": "none",
    "page_sha256": "page-hash",
    "browser_args": "--no-sandbox --ipc-connection-timeout=600 --js-flags=--jitless",
    "profile": "official-index",
    "sampling_interval_ms": 1000,
    "metrics_schema": "xkernel.browser.lifecycle.v1",
}


def manifest(variant: str) -> dict[str, object]:
    implementation: dict[str, object] = {
        "commit": "before-commit" if variant == "before" else "after-commit",
        "git_tag": "v0.1-first-runnable" if variant == "before" else "opt-01",
        "kernel_tree_sha256": f"{variant}-tree",
        "kernel_binary_sha256": f"{variant}-binary",
        "kernel_config_sha256": "same-config",
        "dirty": False,
    }
    if variant == "after":
        implementation["parent_commit"] = "before-commit"
        implementation["optimization_id"] = "opt-01"
    return {
        "schema": compare_perf.SCHEMA,
        "variant": variant,
        "conditions": dict(CONDITIONS),
        "implementation": implementation,
    }


def write_csv(path: Path, variant: str, run_count: int = 5) -> list[str]:
    run_ids = [f"{variant}-{index:02d}" for index in range(1, run_count + 1)]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["metric", "run", "value", "unit", "evidence"])
        writer.writeheader()
        for index, run_id in enumerate(run_ids, 1):
            for metric, unit in compare_perf.METRICS.items():
                value = 100 + index if variant == "before" else 80 + index
                writer.writerow({"metric": metric, "run": run_id, "value": value, "unit": unit, "evidence": f"evidence/{run_id}"})
    return run_ids


class ComparePerfTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.before_manifest_path = self.root / "before.json"
        self.after_manifest_path = self.root / "after.json"
        self.before_manifest_path.write_text(json.dumps(manifest("before")), encoding="utf-8")
        self.after_manifest_path.write_text(json.dumps(manifest("after")), encoding="utf-8")
        self.before_csv = self.root / "before.csv"
        self.after_csv = self.root / "after.csv"
        self.before_runs = write_csv(self.before_csv, "before")
        self.after_runs = write_csv(self.after_csv, "after")
        self.order = self.root / "order.csv"
        self.write_order()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_order(self) -> None:
        with self.order.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=["order", "variant", "run"])
            writer.writeheader()
            n = 1
            for before, after in zip(self.before_runs, self.after_runs):
                writer.writerow({"order": n, "variant": "before", "run": before})
                writer.writerow({"order": n + 1, "variant": "after", "run": after})
                n += 2

    def test_five_run_alternating_comparison_reports_stats_and_direction(self) -> None:
        before_manifest = compare_perf.validate_manifest(self.before_manifest_path, "before")
        after_manifest = compare_perf.validate_manifest(self.after_manifest_path, "after")
        compare_perf.validate_conditions(before_manifest, after_manifest, "parent", "v0.1-first-runnable")
        before = compare_perf.read_samples(self.before_csv, "before")
        after = compare_perf.read_samples(self.after_csv, "after")
        pairs = compare_perf.read_order(self.order, before, after, 5)
        summary = compare_perf.compare(before, after, pairs)
        self.assertEqual(5, summary["browser_startup_ms"]["before"]["n"])
        self.assertEqual(103, summary["browser_startup_ms"]["before"]["median"])
        self.assertEqual(83, summary["browser_startup_ms"]["after"]["median"])
        self.assertTrue(summary["browser_startup_ms"]["direction_consistent"])
        self.assertEqual(7, len(summary))

    def test_non_alternating_execution_order_is_rejected(self) -> None:
        with self.order.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=["order", "variant", "run"])
            writer.writeheader()
            sequence = [("before", self.before_runs[0]), ("after", self.after_runs[0]),
                        ("after", self.after_runs[1]), ("before", self.before_runs[1]),
                        ("before", self.before_runs[2]), ("after", self.after_runs[2]),
                        ("before", self.before_runs[3]), ("after", self.after_runs[3]),
                        ("before", self.before_runs[4]), ("after", self.after_runs[4])]
            for number, (variant, run_id) in enumerate(sequence, 1):
                writer.writerow({"order": number, "variant": variant, "run": run_id})
        before = compare_perf.read_samples(self.before_csv, "before")
        after = compare_perf.read_samples(self.after_csv, "after")
        with self.assertRaisesRegex(compare_perf.ComparisonError, "alternating"):
            compare_perf.read_order(self.order, before, after, 2)

    def test_guest_memory_mismatch_is_rejected(self) -> None:
        changed = manifest("after")
        changed["conditions"]["guest_memory_gib"] = 4
        self.after_manifest_path.write_text(json.dumps(changed), encoding="utf-8")
        before = compare_perf.validate_manifest(self.before_manifest_path, "before")
        with self.assertRaisesRegex(compare_perf.ComparisonError, "2 GiB"):
            compare_perf.validate_manifest(self.after_manifest_path, "after")

    def test_dirty_baseline_is_rejected(self) -> None:
        changed = manifest("before")
        changed["implementation"]["dirty"] = True
        self.before_manifest_path.write_text(json.dumps(changed), encoding="utf-8")
        with self.assertRaisesRegex(compare_perf.ComparisonError, "clean committed tree"):
            compare_perf.validate_manifest(self.before_manifest_path, "before")

    def test_baseline_comparison_does_not_require_first_runnable_tag_to_be_parent(self) -> None:
        after = manifest("after")
        after["implementation"]["parent_commit"] = "a-later-optimization-parent"
        self.after_manifest_path.write_text(json.dumps(after), encoding="utf-8")
        before_row = compare_perf.validate_manifest(self.before_manifest_path, "before")
        after_row = compare_perf.validate_manifest(self.after_manifest_path, "after")
        compare_perf.validate_conditions(before_row, after_row, "baseline", "v0.1-first-runnable")

    def test_incomplete_run_is_rejected(self) -> None:
        with self.before_csv.open(encoding="utf-8") as source:
            rows = list(csv.DictReader(source))
        with self.before_csv.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=["metric", "run", "value", "unit", "evidence"])
            writer.writeheader()
            writer.writerows(row for row in rows if not (row["run"] == self.before_runs[0] and row["metric"] == "renderer_create_ms"))
        with self.assertRaisesRegex(compare_perf.ComparisonError, "incomplete"):
            compare_perf.read_samples(self.before_csv, "before")


if __name__ == "__main__":
    unittest.main()
