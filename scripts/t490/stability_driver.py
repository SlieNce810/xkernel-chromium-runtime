#!/usr/bin/env python3
"""Run a QMP-driven page reload stability sequence with margin over the 30-minute minimum.

The measured clock starts only after the initial official page passes its
strict PPM profile. Ten real Ctrl+R key chords are scheduled two minutes apart;
each reload must produce a new strictly passing QEMU screendump. QEMU status is
sampled every 30 seconds for the full hold. Guest process liveness is recorded by
the default observer and checked by stability_gate.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
import re
import threading
from pathlib import Path
from typing import Any, Callable

from qmp_input import QmpClient, QmpError


SCHEMA = "xkernel.stability.v1"
ASSERT_SCRIPT = Path(__file__).with_name("ppm_assert.py")


def parse_family_snapshot(line: str) -> dict[str, Any] | None:
    """Parse only a complete MP_FAMILY snapshot, excluding MP_FAMILY_COUNT."""

    marker = re.search(r"\bMP_FAMILY_WATCHDOG\s+label=", line)
    if marker is None:
        return None
    family_text = line[marker.start() + len("MP_FAMILY_WATCHDOG") :]
    members = re.findall(
        r"(\d+):([A-Za-z0-9_]+)/([A-Z?])/(\d+)",
        family_text,
    )
    try:
        count = int(re.search(r"\bn=(\d+)\b", family_text).group(1))  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        count = len(members)
    return {
        "members": [
            {"pid": int(pid), "kind": kind, "state": state, "threads": int(threads)}
            for pid, kind, state, threads in members
        ],
        "roles": sorted({kind for _, kind, _, _ in members}),
        "n": count,
    }


class StabilityError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def strict_pass(path: Path, profile: str) -> tuple[bool, str]:
    result = subprocess.run(
        [sys.executable, str(ASSERT_SCRIPT), str(path), "--profile", profile, "--strict", "--quiet"],
        capture_output=True,
        text=True,
        check=False,
    )
    detail = (result.stdout or result.stderr).strip().splitlines()
    return result.returncode == 0, detail[-1] if detail else f"ppm_assert rc={result.returncode}"


def wait_until_not_before(
    deadline: float,
    heartbeat: Callable[[], None],
    poll_seconds: float,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    """Keep QEMU liveness polling while enforcing a post-navigation settle time."""

    while True:
        remaining = deadline - monotonic()
        if remaining <= 0:
            return
        heartbeat()
        sleeper(min(poll_seconds, remaining))


def parse_guest_clock_sync(line: str, expected_run_id: str) -> int | None:
    # ANSI output from /dev/console can end in the printable character `m`
    # immediately before this marker, so a word boundary here would miss it.
    match = re.search(r"MP_METRICS_CLOCK_SYNC\s+run_id=([A-Za-z0-9_.-]+)\s+guest_t_ns=(\d+)\b", line)
    if match is None or match.group(1) != expected_run_id:
        return None
    try:
        return int(match.group(2))
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--console-log", required=True, type=Path,
                        help="live QEMU serial log written by t490_round.sh")
    parser.add_argument("--duration-seconds", type=int, default=1805)
    parser.add_argument("--reload-count", type=int, default=10)
    parser.add_argument("--reload-interval-seconds", type=int, default=120)
    parser.add_argument("--reload-window-seconds", type=int, default=90)
    parser.add_argument(
        "--reload-settle-seconds",
        type=float,
        default=30.0,
        help="minimum delay after QMP navigation input before the first strict screenshot",
    )
    parser.add_argument("--ready-timeout-seconds", type=int, default=1800)
    parser.add_argument(
        "--bootstrap-poll-seconds",
        type=float,
        default=30.0,
        help="initial strict-page screendump interval; reloads use --poll-seconds",
    )
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    parser.add_argument("--heartbeat-seconds", type=int, default=30)
    parser.add_argument(
        "--capture-guest-clock-sync",
        action="store_true",
        help="continuously pair guest CLOCK_MONOTONIC markers with host CLOCK_MONOTONIC receipt times",
    )
    parser.add_argument("--profile", default="official-index")
    parser.add_argument("--schedule-tolerance-seconds", type=int, default=10)
    parser.add_argument("--connect-timeout-seconds", type=float, default=360)
    parser.add_argument(
        "--diagnostic-only",
        action="store_true",
        help="allow non-acceptance reload/hold parameters for a controlled reproduction",
    )
    args = parser.parse_args()

    if args.diagnostic_only:
        if args.duration_seconds < 0:
            parser.error("diagnostic duration must be non-negative")
        if args.reload_count < 1 or args.reload_interval_seconds < 1:
            parser.error("diagnostic reload count and interval must be positive")
    else:
        if args.duration_seconds < 1800:
            parser.error("stability duration must be at least 1800 seconds")
        if args.reload_count != 10:
            parser.error("this gate requires exactly ten scheduled reloads")
        if args.reload_interval_seconds != 120:
            parser.error("reload interval must be 120 seconds")
    if args.reload_window_seconds < 1:
        parser.error("reload window must be positive")
    if args.reload_settle_seconds < 0:
        parser.error("reload settle delay must be non-negative")
    if args.reload_settle_seconds >= args.reload_window_seconds:
        parser.error("reload settle delay must be shorter than the reload window")
    if not args.diagnostic_only and args.reload_settle_seconds < 30:
        parser.error("formal stability requires at least 30 seconds after navigation before screenshots")
    if not args.diagnostic_only and args.reload_window_seconds >= args.reload_interval_seconds:
        parser.error("formal reload window must be shorter than the reload interval")
    if args.poll_seconds <= 0 or args.heartbeat_seconds != 30:
        parser.error("poll must be positive and heartbeat must be 30 seconds")
    out_dir = args.out_dir.resolve()
    events_path = args.events.resolve()
    if out_dir.exists() and any(out_dir.iterdir()):
        parser.error(f"refusing to reuse a non-empty output directory: {out_dir}")
    if events_path.exists():
        parser.error(f"refusing to overwrite event file: {events_path}")
    out_dir.mkdir(parents=True, exist_ok=True)
    events_path.parent.mkdir(parents=True, exist_ok=True)
    qmp_log = out_dir / "qmp-transcript.jsonl"
    temp_ppm = out_dir / ".stability-poll.ppm"
    seq = 0
    event_lock = threading.Lock()
    console_lock = threading.Lock()
    clock_sync_stop = threading.Event()
    clock_sync_thread: threading.Thread | None = None
    clock_id = "t490-host-CLOCK_MONOTONIC"
    console_offset = 0
    console_buffer = ""
    clock_sync_console_offset = 0
    clock_sync_console_buffer = ""
    latest_watchdog: dict[str, Any] = {}
    latest_family: dict[str, Any] = {}

    def emit(kind: str, **values: Any) -> dict[str, Any]:
        nonlocal seq
        with event_lock:
            seq += 1
            now_ns = time.monotonic_ns()
            row = {
                "schema": SCHEMA,
                "run_id": args.run_id,
                "clock_id": clock_id,
                "seq": seq,
                "event_id": f"{args.run_id}:{seq}",
                "t_ns": now_ns,
                "wall_ns": time.time_ns(),
                "event": kind,
                **values,
            }
            with events_path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        return row

    def drain_console_unlocked() -> None:
        nonlocal console_offset, console_buffer, latest_watchdog, latest_family
        try:
            with args.console_log.open("r", encoding="utf-8", errors="replace") as stream:
                stream.seek(console_offset)
                data = stream.read()
                console_offset = stream.tell()
        except OSError:
            return
        if not data:
            return
        text = console_buffer + data
        lines = text.split("\n")
        console_buffer = lines.pop() if lines else ""
        for line in lines:
            if "MP_WATCHDOG" in line:
                fields = dict(re.findall(r"([A-Za-z0-9_]+)=([^\s]+)", line))
                try:
                    sample = {
                        "uptime_s": int(fields.get("uptime_s", "-1")),
                        "weston": fields.get("weston", "unknown"),
                        "chrome": fields.get("chrome", "unknown"),
                        "memfree_kb": int(fields.get("memfree_kb", "-1")),
                    }
                except ValueError:
                    sample = {"uptime_s": -1, "weston": "unknown", "chrome": "unknown"}
                sample["_host_t_ns"] = time.monotonic_ns()
                latest_watchdog = sample
                emit("guest_watchdog_observed", raw=line[-600:],
                     **{key: value for key, value in sample.items() if not key.startswith("_")})
            family_snapshot = parse_family_snapshot(line)
            if family_snapshot is not None:
                latest_family = {
                    **family_snapshot,
                    "_host_t_ns": time.monotonic_ns(),
                }
                emit("guest_process_snapshot", raw=line[-1000:],
                     **family_snapshot)
            if "MP_PROC_EVENT event=exited" in line:
                pid_match = re.search(r"\bpid=(\d+)", line)
                kind_match = re.search(r"\bkind=([A-Za-z0-9_]+)", line)
                emit("guest_process_exit", pid=int(pid_match.group(1)) if pid_match else None,
                     kind=kind_match.group(1) if kind_match else "unknown", raw=line[-1000:])
            if re.search(r"out of memory|oom-kill|killed process|wayland.*(disconnect|closed)|weston.*(fatal|quitting)", line, re.I):
                emit("guest_exception", raw=line[-1000:])

    def drain_console() -> None:
        with console_lock:
            drain_console_unlocked()

    def poll_guest_clock_sync() -> None:
        nonlocal clock_sync_console_offset, clock_sync_console_buffer
        try:
            with args.console_log.open("r", encoding="utf-8", errors="replace") as stream:
                stream.seek(clock_sync_console_offset)
                data = stream.read()
                clock_sync_console_offset = stream.tell()
        except OSError:
            return
        if not data:
            return
        lines = (clock_sync_console_buffer + data).split("\n")
        clock_sync_console_buffer = lines.pop() if lines else ""
        for line in lines:
            guest_clock_ns = parse_guest_clock_sync(line, args.run_id)
            if guest_clock_ns is not None:
                receive_ns = time.monotonic_ns()
                emit(
                    "clock_sync",
                    guest_clock_id="LINUX_CLOCK_MONOTONIC",
                    guest_t_ns=guest_clock_ns,
                    host_receive_t_ns=receive_ns,
                    source="guest-console",
                )

    def watch_console() -> None:
        while not clock_sync_stop.wait(0.1):
            poll_guest_clock_sync()

    client = QmpClient(str(args.socket), qmp_log, qmp_send_key=True, input_target="auto")
    rc = 1

    def request_qemu_quit(reason: str) -> None:
        emit("qemu_quit_requested", reason=reason)
        try:
            client.command("quit")
        except (OSError, QmpError, TimeoutError):
            pass

    try:
        client.connect(args.connect_timeout_seconds)
        emit("qmp_connected", socket=args.socket)
        if args.capture_guest_clock_sync:
            clock_sync_thread = threading.Thread(target=watch_console, name="guest-clock-sync", daemon=True)
            clock_sync_thread.start()

        def wait_for_page(
            label: str,
            navigation_id: str,
            deadline: float,
            poll_seconds: float,
            not_before: float | None = None,
        ) -> tuple[Path | None, bool]:
            if not_before is not None and time.monotonic() < not_before:
                emit(
                    "navigation_settle_wait",
                    navigation_id=navigation_id,
                    settle_seconds=args.reload_settle_seconds,
                    first_screendump_not_before_host_monotonic_ns=int(not_before * 1_000_000_000),
                )
                wait_until_not_before(not_before, heartbeat, poll_seconds)
            attempt = 0
            last_failed: Path | None = None
            while time.monotonic() < deadline:
                attempt += 1
                client.screendump(temp_ppm)
                passed, detail = strict_pass(temp_ppm, args.profile)
                if passed:
                    target = out_dir / f"{label}.ppm"
                    shutil.copyfile(temp_ppm, target)
                    emit(
                        "screendump_verified",
                        navigation_id=navigation_id,
                        profile=args.profile,
                        pass_result=True,
                        strict=True,
                        capture_path=f"stability/{target.name}",
                        sha256=sha256(target),
                        sampling_interval_ms=poll_seconds * 1000,
                        attempt=attempt,
                    )
                    return target, True
                last_failed = temp_ppm
                emit("page_poll", navigation_id=navigation_id, attempt=attempt, pass_result=False, detail=detail)
                heartbeat()
                time.sleep(poll_seconds)
            if last_failed and last_failed.exists():
                failure = out_dir / f"{label}-timeout.ppm"
                shutil.copyfile(last_failed, failure)
                emit("page_timeout_screenshot", navigation_id=navigation_id,
                     capture_path=f"stability/{failure.name}",
                     sha256=sha256(failure), profile=args.profile)
            emit("page_timeout", navigation_id=navigation_id, attempts=attempt)
            return None, False

        monitor_start_ns: int | None = None
        next_heartbeat_ns: int | None = None

        def heartbeat() -> None:
            nonlocal next_heartbeat_ns
            drain_console()
            if monitor_start_ns is None or next_heartbeat_ns is None:
                return
            now = time.monotonic_ns()
            while now >= next_heartbeat_ns:
                try:
                    status = client.command("query-status").get("return", {})
                    status_name = status.get("status", "unknown") if isinstance(status, dict) else "unknown"
                    running = status_name == "running"
                    error = None
                except (OSError, QmpError, TimeoutError) as exc:
                    status_name = "unavailable"
                    running = False
                    error = str(exc)
                sample_t_ns = time.monotonic_ns()
                watchdog_age_s = ((sample_t_ns - latest_watchdog["_host_t_ns"]) / 1_000_000_000
                                  if "_host_t_ns" in latest_watchdog else None)
                family_age_s = ((sample_t_ns - latest_family["_host_t_ns"]) / 1_000_000_000
                                if "_host_t_ns" in latest_family else None)
                emit("host_liveness", status=status_name, running=running, error=error,
                     guest_watchdog={key: value for key, value in latest_watchdog.items() if not key.startswith("_")},
                     guest_family={key: value for key, value in latest_family.items() if not key.startswith("_")},
                     guest_watchdog_age_s=watchdog_age_s, guest_family_age_s=family_age_s)
                next_heartbeat_ns += args.heartbeat_seconds * 1_000_000_000

        init_deadline = time.monotonic() + args.ready_timeout_seconds
        init_start_ns = time.monotonic_ns()
        emit("initial_page_wait", profile=args.profile, timeout_seconds=args.ready_timeout_seconds)
        initial_path, initial_ok = wait_for_page(
            "load-00-initial", "nav-00", init_deadline, args.bootstrap_poll_seconds
        )
        if not initial_ok or initial_path is None:
            emit("result", pass_result=False, reason="initial strict page gate timed out", reloads_passed=0)
            request_qemu_quit("initial strict page gate timed out")
            print("STABILITY_DRIVER_FAIL initial strict page gate timed out", file=sys.stderr)
            return 1

        monitor_start_ns = time.monotonic_ns()
        next_heartbeat_ns = monitor_start_ns + args.heartbeat_seconds * 1_000_000_000
        emit("page_ready", navigation_id="nav-00", capture_path=f"stability/{initial_path.name}",
             sha256=sha256(initial_path), profile=args.profile, strict=True, pass_result=True,
             ready_elapsed_ms=(monitor_start_ns - init_start_ns) / 1_000_000)
        completed = 0
        schedule_slips: list[float] = []
        for index in range(1, args.reload_count + 1):
            scheduled_ns = monitor_start_ns + index * args.reload_interval_seconds * 1_000_000_000
            while time.monotonic_ns() < scheduled_ns:
                heartbeat()
                remaining = (scheduled_ns - time.monotonic_ns()) / 1_000_000_000
                time.sleep(min(1.0, max(0.05, remaining)))
            actual_ns = time.monotonic_ns()
            slip_s = (actual_ns - scheduled_ns) / 1_000_000_000
            schedule_slips.append(slip_s)
            navigation_id = f"nav-{index:02d}"
            try:
                client.key_chord(["ctrl", "r"])
                navigation_t_ns = time.monotonic_ns()
                screenshot_not_before = navigation_t_ns / 1_000_000_000 + args.reload_settle_seconds
                emit("navigation_requested", navigation_id=navigation_id, action="ctrl+r",
                     transport="QMP send-key", scheduled_t_ns=scheduled_ns,
                     schedule_slip_ms=slip_s * 1000,
                     request_host_monotonic_ns=navigation_t_ns,
                     first_screendump_not_before_host_monotonic_ns=int(screenshot_not_before * 1_000_000_000))
            except (OSError, QmpError, TimeoutError) as exc:
                emit("navigation_error", navigation_id=navigation_id, error=str(exc))
                break
            load_deadline = time.monotonic() + args.reload_window_seconds
            path, passed = wait_for_page(
                f"load-{index:02d}-reload", navigation_id, load_deadline, args.poll_seconds,
                not_before=screenshot_not_before,
            )
            if not passed or path is None:
                break
            completed += 1
            emit("page_verdict", navigation_id=navigation_id, pass_result=True,
                 strict=True, profile=args.profile, screenshot=f"stability/{path.name}", sha256=sha256(path))

        end_ns = monitor_start_ns + args.duration_seconds * 1_000_000_000
        while time.monotonic_ns() < end_ns:
            heartbeat()
            time.sleep(min(1.0, max(0.05, (end_ns - time.monotonic_ns()) / 1_000_000_000)))
        heartbeat()
        measured_seconds = (time.monotonic_ns() - monitor_start_ns) / 1_000_000_000
        success = completed == args.reload_count and measured_seconds >= args.duration_seconds
        emit("monitor_end", measured_seconds=measured_seconds, reloads_passed=completed,
             reloads_required=args.reload_count, schedule_slips_seconds=schedule_slips)
        emit("result", pass_result=success, reloads_passed=completed,
             reloads_required=args.reload_count, measured_seconds=measured_seconds)
        request_qemu_quit("measured hold finished")
        rc = 0 if success else 1
        print(f"STABILITY_DRIVER_RESULT pass={int(success)} duration={measured_seconds:.1f} reloads={completed}/{args.reload_count}")
        return rc
    except (OSError, QmpError, TimeoutError, StabilityError) as exc:
        emit("fatal_error", error=str(exc))
        request_qemu_quit(f"driver error: {exc}")
        print(f"STABILITY_DRIVER_ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        clock_sync_stop.set()
        if clock_sync_thread is not None:
            clock_sync_thread.join(timeout=2)
        drain_console()
        try:
            temp_ppm.unlink()
        except FileNotFoundError:
            pass
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
