#!/usr/bin/env python3
"""Sample one running QEMU process through readable /proc counters.

This is a permission-compatible host-side fallback when perf_event_open/eBPF
tracepoints are restricted. It reports process CPU time, resident memory,
page-fault counters and context switches; it does not claim hardware cycles.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import time
from pathlib import Path


def read_sample(pid: int, page_size: int, ticks_per_second: int) -> dict[str, float] | None:
    proc = Path("/proc") / str(pid)
    try:
        stat_text = (proc / "stat").read_text(encoding="ascii")
        tail = stat_text.rsplit(")", 1)[1].strip().split()
        user_ticks = int(tail[11])
        system_ticks = int(tail[12])
        minflt = int(tail[7])
        majflt = int(tail[9])
        rss_pages = int(tail[21])
        status_text = (proc / "status").read_text(encoding="ascii", errors="replace")
    except (OSError, IndexError, ValueError):
        return None
    status: dict[str, int] = {}
    for line in status_text.splitlines():
        if line.startswith("voluntary_ctxt_switches:"):
            status["voluntary_ctxt_switches"] = int(line.split(":", 1)[1].strip())
        elif line.startswith("nonvoluntary_ctxt_switches:"):
            status["nonvoluntary_ctxt_switches"] = int(line.split(":", 1)[1].strip())
    return {
        "user_cpu_sec": user_ticks / ticks_per_second,
        "system_cpu_sec": system_ticks / ticks_per_second,
        "minflt": float(minflt),
        "majflt": float(majflt),
        "rss_kb": rss_pages * page_size / 1024,
        "voluntary_ctxt_switches": float(status.get("voluntary_ctxt_switches", 0)),
        "nonvoluntary_ctxt_switches": float(status.get("nonvoluntary_ctxt_switches", 0)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("--interval must be positive")

    page_size = os.sysconf("SC_PAGE_SIZE")
    ticks_per_second = os.sysconf("SC_CLK_TCK")
    started_wall = time.time()
    started_mono = time.monotonic()
    samples: list[dict[str, float]] = []
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    with args.csv.open("x", newline="", encoding="utf-8") as stream:
        fields = [
            "elapsed_sec", "epoch_sec", "pid", "user_cpu_sec", "system_cpu_sec",
            "total_cpu_sec", "avg_cpu_percent", "rss_kb", "minflt", "majflt",
            "voluntary_ctxt_switches", "nonvoluntary_ctxt_switches",
        ]
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        while True:
            sample = read_sample(args.pid, page_size, ticks_per_second)
            if sample is None:
                break
            elapsed = max(time.monotonic() - started_mono, 0.001)
            cpu = sample["user_cpu_sec"] + sample["system_cpu_sec"]
            row = {
                "elapsed_sec": f"{elapsed:.3f}",
                "epoch_sec": f"{time.time():.3f}",
                "pid": args.pid,
                **{key: f"{value:.3f}" for key, value in sample.items()},
                "total_cpu_sec": f"{cpu:.3f}",
                "avg_cpu_percent": f"{cpu / elapsed * 100:.3f}",
            }
            writer.writerow(row)
            stream.flush()
            samples.append(sample)
            time.sleep(args.interval)

    ended_wall = time.time()
    elapsed = max(ended_wall - started_wall, 0.001)
    if not samples:
        summary = {"pid": args.pid, "elapsed_sec": elapsed, "samples": 0, "status": "process_not_observable"}
    else:
        first, last = samples[0], samples[-1]
        cpu_delta = (last["user_cpu_sec"] + last["system_cpu_sec"]) - (
            first["user_cpu_sec"] + first["system_cpu_sec"]
        )
        summary = {
            "pid": args.pid,
            "samples": len(samples),
            "started_epoch_sec": started_wall,
            "ended_epoch_sec": ended_wall,
            "elapsed_sec": elapsed,
            "qemu_cpu_seconds_delta": max(cpu_delta, 0),
            "qemu_avg_cpu_percent_one_core_scale": max(cpu_delta, 0) / elapsed * 100,
            "qemu_peak_rss_kb": max(sample["rss_kb"] for sample in samples),
            "qemu_minflt_delta": max(last["minflt"] - first["minflt"], 0),
            "qemu_majflt_delta": max(last["majflt"] - first["majflt"], 0),
            "qemu_voluntary_ctxt_switch_delta": max(
                last["voluntary_ctxt_switches"] - first["voluntary_ctxt_switches"], 0
            ),
            "qemu_nonvoluntary_ctxt_switch_delta": max(
                last["nonvoluntary_ctxt_switches"] - first["nonvoluntary_ctxt_switches"], 0
            ),
            "counter_source": "/proc/<pid>/{stat,status}",
            "limitation": "No perf_event_open hardware cycles or kernel tracepoint attribution.",
        }
    with args.summary.open("x", encoding="utf-8") as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(f"QEMU_OBSERVER pid={args.pid} samples={len(samples)} elapsed={elapsed:.3f}s")
    return 0 if samples else 1


if __name__ == "__main__":
    raise SystemExit(main())
