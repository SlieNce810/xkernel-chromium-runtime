from __future__ import annotations

import base64
import gzip
import hashlib
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t490"))
import extract_perf_memory  # noqa: E402


RUN_ID = "metric-memory-test-01"


def make_console(root: Path, *, end_marker: bool = True, sequence_gap: bool = False,
                 unsafe_member: bool = False, sampler_failed: bool = False) -> Path:
    members = {
        "lifecycle-events.jsonl": (
            json.dumps({"schema": "xkernel.browser.lifecycle.v1", "run_id": RUN_ID,
                        "clock_id": "LINUX_CLOCK_MONOTONIC", "seq": 1, "t_ns": 100,
                        "event_id": f"{RUN_ID}:1", "event": "browser_launch_requested"}) + "\n"
        ).encode(),
        "memory-samples.csv": (
            "run_id,clock_id,sample_id,t_ns,pid,ppid,process_instance,rss_kb,pss_kb,uss_kb\n"
            f"{RUN_ID},LINUX_CLOCK_MONOTONIC,sample-1,200,10,1,browser-10,100,90,80\n"
        ).encode(),
        "memory-sampling-errors.log": b"sample=2 pid=10 smaps_rollup=unavailable\n" if sampler_failed else b"",
        "proc-tree-sampler.status": f"run_id={RUN_ID}\nresult={'FAIL' if sampler_failed else 'PASS'}\nsamples=1\n".encode(),
    }
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, payload in members.items():
            info = tarfile.TarInfo("../unsafe" if unsafe_member and name == "memory-sampling-errors.log" else name)
            info.size = len(payload)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(payload))
    raw_tar = buffer.getvalue()
    compressed = gzip.compress(raw_tar, mtime=0)
    encoded = base64.b64encode(compressed).decode("ascii")
    chunks = [encoded[index:index + 256] for index in range(0, len(encoded), 256)]
    lines = [
        f"MP_PERF_MEMORY_EXPORT_BEGIN run_id={RUN_ID} bytes={len(raw_tar)} chunks={len(chunks)} "
        f"sha256={hashlib.sha256(raw_tar).hexdigest()} gzip_bytes={len(compressed)} "
        f"gzip_sha256={hashlib.sha256(compressed).hexdigest()}"
    ]
    for index, chunk in enumerate(chunks):
        sequence = index + 1 if sequence_gap and index == 1 else index
        lines.append(f"MP_PERF_MEMORY_DATA run_id={RUN_ID} seq={sequence} len={len(chunk)} {chunk}")
    if end_marker:
        lines.append(f"MP_PERF_MEMORY_EXPORT_END run_id={RUN_ID} encoding=gzip+base64 chunks={len(chunks)}")
    path = root / "console.log"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


class ExtractPerfMemoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_complete_memory_bundle_extracts_and_verifies(self) -> None:
        console = make_console(self.root)
        out = self.root / "extracted"

        summary = extract_perf_memory.extract(console, out, RUN_ID)

        self.assertEqual("xkernel.proc-tree-memory-export.v1", summary["schema"])
        self.assertEqual(1, summary["memory_rows"])
        self.assertTrue((out / "memory-samples.csv").is_file())
        self.assertTrue((out / "guest-samples.tar.gz").is_file())
        self.assertTrue(summary["valid"])

    def test_missing_end_marker_is_rejected(self) -> None:
        console = make_console(self.root, end_marker=False)
        with self.assertRaisesRegex(extract_perf_memory.MemoryExportError, "missing MP_PERF_MEMORY_EXPORT_END"):
            extract_perf_memory.extract(console, self.root / "out", RUN_ID)

    def test_out_of_order_sequence_is_rejected(self) -> None:
        console = make_console(self.root, sequence_gap=True)
        with self.assertRaisesRegex(extract_perf_memory.MemoryExportError, "sequence mismatch"):
            extract_perf_memory.extract(console, self.root / "out", RUN_ID)

    def test_run_identifier_mismatch_is_rejected(self) -> None:
        console = make_console(self.root)
        with self.assertRaisesRegex(extract_perf_memory.MemoryExportError, "does not match"):
            extract_perf_memory.extract(console, self.root / "out", "wrong-run")

    def test_unsafe_tar_path_is_rejected(self) -> None:
        console = make_console(self.root, unsafe_member=True)
        with self.assertRaisesRegex(extract_perf_memory.MemoryExportError, "unsafe tar member path"):
            extract_perf_memory.extract(console, self.root / "out", RUN_ID)

    def test_failed_sampler_bundle_is_preserved_and_marked_invalid(self) -> None:
        console = make_console(self.root, sampler_failed=True)
        out = self.root / "invalid-extracted"

        summary = extract_perf_memory.extract(console, out, RUN_ID)

        self.assertFalse(summary["valid"])
        self.assertIn("sampler status does not report PASS", summary["errors"])
        self.assertIn("sampler recorded 1 memory/tree errors", summary["errors"])
        self.assertEqual(1, summary["memory_sampling_errors"])
        self.assertTrue((out / "memory-samples.csv").is_file())


if __name__ == "__main__":
    unittest.main()
