from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "t490" / "extract_proc_tree_smoke.py"
SPEC = importlib.util.spec_from_file_location("extract_proc_tree_smoke", MODULE_PATH)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)

RUN_ID = "proc-tree-smoke-01"
HEADER = "run_id,clock_id,sample_id,t_ns,pid,ppid,process_instance,rss_kb,pss_kb,uss_kb"
TIMING_HEADER = HEADER + ",tree_snapshot_total_ns,tree_snapshot_resident_walk_ns,tree_snapshot_mapcount_ns,tree_snapshot_rollup_ns,tree_snapshot_format_ns,tree_snapshot_process_count,tree_snapshot_resident_pages,tree_smaps_rollup_read_ns,sample_work_ns"


def fixture_console(*, rows: int = 16, root_ticks: int = 159, zero_instance: bool = False, events: int = 4, duplicate: bool = False, timing: bool = False, timing_mismatch: bool = False) -> str:
    fields = ["S", "1"] + ["0"] * 17 + [str(root_ticks)]
    root_stat = "5 (autorun.sh) " + " ".join(fields)
    lines = [
        f"PROC_TREE_SMOKE_BEGIN root_pid=5 root_stat={root_stat} launch_ns=1000000000",
        f"run_id={RUN_ID}", "result=PASS", "samples=8", "process_instances=2",
        "missed=0", "memory_source=procfs-tree-smaps_rollup", "finished_t_ns=9000000000",
        f"PROC_TREE_SMOKE run_id={RUN_ID} sample_rows=16 processes_started=2 memory_errors=0 bad_values=0 start_time_count=2 bad_start_times=0",
        "PROC_TREE_SMOKE_MEMORY_CSV_BEGIN", TIMING_HEADER if timing else HEADER,
    ]
    rows_text = []
    for sample in range(1, 9):
        for pid, ppid, instance, rss, pss, uss in [(5, 1, f"5-{0 if zero_instance else root_ticks}", 588, 372, 156), (11, 5, "11-189", 164, 164, 164)]:
            row = f"{RUN_ID},LINUX_CLOCK_MONOTONIC,{sample},{sample * 1000000000},{pid},{ppid},{instance},{rss},{pss},{uss}"
            if timing:
                total = 100000 + int(timing_mismatch and pid == 11 and sample == 1)
                row += f",{total},30000,20000,10000,5000,18,50,110000,250000"
            rows_text.append(row)
    if duplicate:
        rows_text[-1] = rows_text[0]
    lines.extend(rows_text[:rows])
    lines.append("PROC_TREE_SMOKE_EVENTS_BEGIN")
    records = [
        {"schema":"xkernel.browser.lifecycle.v1","run_id":RUN_ID,"clock_id":"LINUX_CLOCK_MONOTONIC","seq":1,"event_id":f"{RUN_ID}:1","t_ns":1000000000,"event":"browser_launch_requested"},
        {"schema":"xkernel.browser.lifecycle.v1","run_id":RUN_ID,"clock_id":"LINUX_CLOCK_MONOTONIC","seq":2,"event_id":f"{RUN_ID}:2","t_ns":1800000000,"event":"process_started","pid":5,"ppid":1,"process_instance":f"5-{root_ticks}","role":"browser"},
        {"schema":"xkernel.browser.lifecycle.v1","run_id":RUN_ID,"clock_id":"LINUX_CLOCK_MONOTONIC","seq":3,"event_id":f"{RUN_ID}:3","t_ns":1800000000,"event":"process_started","pid":11,"ppid":5,"process_instance":"11-189","role":"browser_child","parent_process_instance":f"5-{root_ticks}"},
        {"schema":"xkernel.browser.lifecycle.v1","run_id":RUN_ID,"clock_id":"LINUX_CLOCK_MONOTONIC","seq":4,"event_id":f"{RUN_ID}:4","t_ns":9000000000,"event":"memory_sampling_finished"},
    ]
    lines.extend(json.dumps(record, separators=(",", ":")) for record in records[:events])
    lines.extend(["PROC_TREE_SMOKE_ROOT_SMAPS_BEGIN pid=5", "Rss:\t588 kB", "Pss:\t334 kB", "USS:\t152 kB", "Shared:\t436 kB", "PROC_TREE_SMOKE_PASS"])
    return "\n".join(lines) + "\n"


class ExtractProcTreeSmokeTests(unittest.TestCase):
    def run_extract(self, console: str) -> tuple[dict, Path]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        console_path = root / "console.log"
        console_path.write_text(console, encoding="utf-8")
        out = root / "out"
        summary = module.extract_smoke(console_path, out, RUN_ID)
        return summary, out

    def test_extracts_all_memory_rows_and_events(self) -> None:
        summary, out = self.run_extract(fixture_console())
        with (out / "memory-samples.csv").open(encoding="utf-8", newline="") as stream:
            rows = list(csv.DictReader(stream))
        events = [json.loads(line) for line in (out / "lifecycle-events.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(summary["memory_rows"], 16)
        self.assertEqual(len(rows), 16)
        self.assertEqual([event["seq"] for event in events], [1, 2, 3, 4])
        self.assertEqual(summary["root_start_ticks"], 159)
        self.assertEqual(summary["memory_source"], "procfs-tree-smaps_rollup")

    def test_extracts_and_summarizes_timing_columns(self) -> None:
        summary, out = self.run_extract(fixture_console(timing=True))
        with (out / "memory-samples.csv").open(encoding="utf-8", newline="") as stream:
            rows = list(csv.DictReader(stream))
        self.assertEqual(len(rows), 16)
        timing = summary["tree_snapshot_timing"]
        self.assertEqual(timing["fields"]["tree_snapshot_total_ns"]["samples"], 8)
        self.assertEqual(timing["fields"]["tree_snapshot_total_ns"]["median"], 100000)
        self.assertIn("system-wide", timing["process_count_semantics"])

    def test_rejects_inconsistent_timing_metadata_within_sample(self) -> None:
        with self.assertRaisesRegex(module.ExtractionError, "inconsistent timing metadata"):
            self.run_extract(fixture_console(timing=True, timing_mismatch=True))

    def test_rejects_a_missing_memory_row(self) -> None:
        with self.assertRaises(module.ExtractionError):
            self.run_extract(fixture_console(rows=15))

    def test_rejects_zero_starttime(self) -> None:
        with self.assertRaises(module.ExtractionError):
            self.run_extract(fixture_console(root_ticks=0, zero_instance=True))

    def test_rejects_duplicate_rows(self) -> None:
        with self.assertRaises(module.ExtractionError):
            self.run_extract(fixture_console(duplicate=True))

    def test_rejects_missing_lifecycle_event(self) -> None:
        with self.assertRaises(module.ExtractionError):
            self.run_extract(fixture_console(events=3))


if __name__ == "__main__":
    unittest.main()
