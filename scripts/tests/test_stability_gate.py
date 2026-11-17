from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t490"))
import stability_gate  # noqa: E402


RUN_ID = "stability-fixture-01"
SECOND = 1_000_000_000


def make_evidence(root: Path, *, fail_liveness_at: int | None = None,
                  schedule_slip_seconds: int = 0,
                  missing_renderer_at: int | None = None) -> tuple[Path, Path, Path]:
    evidence = root / "evidence"
    image_dir = evidence / "stability"
    image_dir.mkdir(parents=True)
    ppm = image_dir / "load-00-initial.ppm"
    ppm.write_bytes(b"P6\n1 1\n255\n\x10\x20\x30")
    digest = hashlib.sha256(ppm.read_bytes()).hexdigest()
    events: list[dict[str, object]] = []
    seq = 0

    def add(t_ns: int, kind: str, **fields: object) -> None:
        nonlocal seq
        seq += 1
        events.append({
            "schema": stability_gate.SCHEMA,
            "run_id": RUN_ID,
            "clock_id": "t490-host-CLOCK_MONOTONIC",
            "seq": seq,
            "event_id": f"event-{seq}",
            "t_ns": t_ns,
            "event": kind,
            **fields,
        })

    add(0, "page_ready", navigation_id="nav-00", capture_path=f"stability/{ppm.name}",
        sha256=digest, profile="official-index", strict=True, pass_result=True)
    for index in range(1, 11):
        scheduled = index * 120 * SECOND
        actual = scheduled + schedule_slip_seconds * SECOND
        add(actual, "navigation_requested", navigation_id=f"nav-{index:02d}",
            action="ctrl+r", transport="QMP send-key", scheduled_t_ns=scheduled)
        image = image_dir / f"load-{index:02d}-reload.ppm"
        image.write_bytes(ppm.read_bytes())
        image_hash = hashlib.sha256(image.read_bytes()).hexdigest()
        load_done = actual + SECOND
        add(load_done, "screendump_verified", navigation_id=f"nav-{index:02d}",
            profile="official-index", pass_result=True, strict=True,
            capture_path=f"stability/{image.name}", sha256=image_hash, sampling_interval_ms=5000)
        add(load_done, "page_verdict", navigation_id=f"nav-{index:02d}",
            profile="official-index", pass_result=True, strict=True,
            screenshot=f"stability/{image.name}", sha256=image_hash)
    for index in range(1, 61):
        t_ns = index * 30 * SECOND
        alive = index != fail_liveness_at
        roles = ["browser_child", "zygote_child"] if index != missing_renderer_at else ["browser_child"]
        add(t_ns, "host_liveness", status="running" if alive else "paused",
            running=alive,
            guest_watchdog={"weston": "yes", "chrome": "yes"},
            guest_family={"roles": roles, "n": 3 if len(roles) == 2 else 2},
            guest_watchdog_age_s=1.0, guest_family_age_s=1.0)
    add(1800 * SECOND, "monitor_end", measured_seconds=1800.0,
        reloads_passed=10, reloads_required=10)
    add(1800 * SECOND, "result", pass_result=True, reloads_passed=10,
        reloads_required=10, measured_seconds=1800.0)
    events.sort(key=lambda row: int(row["t_ns"]))
    for index, row in enumerate(events, 1):
        row["seq"] = index
        row["event_id"] = f"event-{index}"
    event_path = root / "stability-events.jsonl"
    event_path.write_text("".join(json.dumps(row) + "\n" for row in events), encoding="utf-8")
    console = root / "console.log"
    console.write_text("stable guest log\n", encoding="utf-8")
    return evidence, event_path, console


class StabilityGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_gate(self, evidence: Path, events: Path, console: Path, out: Path) -> int:
        argv = [
            "stability_gate.py", str(evidence), "--events", str(events),
            "--console-log", str(console), "--run-id", RUN_ID, "--out", str(out),
        ]
        with patch.object(sys, "argv", argv), patch("stability_gate.subprocess.run") as run:
            run.return_value.returncode = 0
            return stability_gate.main()

    def test_valid_30_minute_ten_reload_gate_passes(self) -> None:
        evidence, events, console = make_evidence(self.root)
        out = evidence / "stability-gate.json"
        self.assertEqual(0, self.run_gate(evidence, events, console, out))
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(result["pass"])
        self.assertEqual(10, result["strict_reload_passes"])
        self.assertEqual(60, result["qemu_liveness_samples"])

    def test_paused_qemu_liveness_fails(self) -> None:
        evidence, events, console = make_evidence(self.root, fail_liveness_at=20)
        with self.assertRaisesRegex(stability_gate.GateError, "QEMU was not running"):
            self.run_gate(evidence, events, console, evidence / "stability-gate.json")

    def test_missed_two_minute_navigation_schedule_fails(self) -> None:
        evidence, events, console = make_evidence(self.root, schedule_slip_seconds=15)
        with self.assertRaisesRegex(stability_gate.GateError, "schedule tolerance"):
            self.run_gate(evidence, events, console, evidence / "stability-gate.json")

    def test_renderer_family_loss_fails(self) -> None:
        evidence, events, console = make_evidence(self.root, missing_renderer_at=20)
        with self.assertRaisesRegex(stability_gate.GateError, "process family missing"):
            self.run_gate(evidence, events, console, evidence / "stability-gate.json")


if __name__ == "__main__":
    unittest.main()
