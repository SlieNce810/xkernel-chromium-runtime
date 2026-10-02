#!/usr/bin/env python3
"""Send reproducible keyboard and mouse events through QEMU QMP.

The input path under test is QEMU virtio-input -> guest evdev -> libinput ->
Weston -> Chromium.  This helper intentionally uses only the public QMP
``input-send-event`` command.  HMP ``sendkey``/``mouse_move`` is used only as
an explicit compatibility fallback when a QEMU build rejects an event.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path
from typing import Any, Iterable


class QmpError(RuntimeError):
    """A QMP command returned an error or the monitor closed."""


class QmpClient:
    def __init__(self, path: str, output: Path, force_hmp: bool = False) -> None:
        self.path = path
        self.output = output
        self.force_hmp = force_hmp
        self.sock: socket.socket | None = None
        self._rx = b""
        self._seq = 0

    def _record(self, kind: str, value: Any) -> None:
        self.output.parent.mkdir(parents=True, exist_ok=True)
        with self.output.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.time(), "kind": kind, "value": value},
                                ensure_ascii=False, sort_keys=True) + "\n")

    def _read_json(self, deadline: float) -> dict[str, Any]:
        assert self.sock is not None
        while True:
            newline = self._rx.find(b"\n")
            if newline >= 0:
                raw, self._rx = self._rx[:newline], self._rx[newline + 1 :]
                if not raw.strip():
                    continue
                try:
                    value = json.loads(raw.decode("utf-8"))
                except json.JSONDecodeError as exc:
                    raise QmpError(f"invalid QMP JSON: {raw!r}") from exc
                self._record("rx", value)
                return value
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise QmpError("QMP response timeout")
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise QmpError("QMP socket closed")
            self._rx += chunk

    def connect(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(max(0.1, deadline - time.monotonic()))
                sock.connect(self.path)
                self.sock = sock
                greeting = self._read_json(deadline)
                self._record("connected", {"socket": self.path, "greeting": greeting})
                self.command("qmp_capabilities")
                return
            except (OSError, QmpError) as exc:
                last_error = exc
                if self.sock is not None:
                    self.sock.close()
                    self.sock = None
                time.sleep(0.5)
        raise QmpError(f"cannot connect to QMP socket {self.path}: {last_error}")

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def command(self, execute: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        if self.sock is None:
            raise QmpError("QMP is not connected")
        self._seq += 1
        request: dict[str, Any] = {"execute": execute, "id": self._seq}
        if arguments:
            request["arguments"] = arguments
        raw = (json.dumps(request, ensure_ascii=False) + "\r\n").encode("utf-8")
        self._record("tx", request)
        self.sock.sendall(raw)
        deadline = time.monotonic() + 10.0
        while True:
            response = self._read_json(deadline)
            if "event" in response and "id" not in response:
                continue
            if response.get("id") != self._seq:
                continue
            if "error" in response:
                raise QmpError(json.dumps(response["error"], ensure_ascii=False))
            return response

    def hmp(self, command_line: str) -> dict[str, Any]:
        return self.command("human-monitor-command", {"command-line": command_line})

    def event(self, value: dict[str, Any]) -> None:
        self.command("input-send-event", {"events": [value]})

    def key(self, qcode: str) -> None:
        if self.force_hmp:
            self.hmp(f"sendkey {qcode}")
            self._record("action", {"op": "key", "qcode": qcode, "transport": "hmp"})
            return
        value = {"type": "key", "data": {"down": True,
                                             "key": {"type": "qcode", "data": qcode}}}
        try:
            self.event(value)
            value["data"]["down"] = False
            self.event(value)
            self._record("action", {"op": "key", "qcode": qcode, "transport": "qmp"})
        except QmpError:
            self.hmp(f"sendkey {qcode}")
            self._record("action", {"op": "key", "qcode": qcode, "transport": "hmp"})

    def relative(self, axis: str, value: int) -> None:
        if self.force_hmp:
            dx = value if axis == "x" else 0
            dy = value if axis == "y" else 0
            self.hmp(f"mouse_move {dx} {dy}")
            self._record("action", {"op": "relative", "axis": axis, "value": value,
                                     "transport": "hmp"})
            return
        event = {"type": "rel", "data": {"axis": axis, "value": value}}
        try:
            self.event(event)
            self._record("action", {"op": "relative", "axis": axis, "value": value,
                                     "transport": "qmp"})
        except QmpError:
            # HMP takes both axes in one relative motion command.  Callers use
            # this fallback only for a single axis, so keep the other at zero.
            dx = value if axis == "x" else 0
            dy = value if axis == "y" else 0
            self.hmp(f"mouse_move {dx} {dy}")
            self._record("action", {"op": "relative", "axis": axis, "value": value,
                                     "transport": "hmp"})

    def click(self) -> None:
        if self.force_hmp:
            self.hmp("mouse_button 1")
            self.hmp("mouse_button 0")
            self._record("action", {"op": "click", "transport": "hmp"})
            return
        try:
            self.event({"type": "btn", "data": {"button": "left", "down": True}})
            self.event({"type": "btn", "data": {"button": "left", "down": False}})
            self._record("action", {"op": "click", "transport": "qmp"})
        except QmpError:
            self.hmp("mouse_button 1")
            self.hmp("mouse_button 0")
            self._record("action", {"op": "click", "transport": "hmp"})


def pause(client: QmpClient, seconds: float, reason: str) -> None:
    client._record("sleep", {"seconds": seconds, "reason": reason})
    time.sleep(seconds)


def move_to(client: QmpClient, x: int, y: int) -> None:
    # Relative virtio-mouse events have no portable absolute origin.  A large
    # negative move clamps the pointer at the top-left on QEMU's display, after
    # which the requested pixel offset is deterministic for a fresh VM.
    client.relative("x", -2000)
    client.relative("y", -2000)
    client.relative("x", x)
    client.relative("y", y)


def click_at(client: QmpClient, x: int, y: int, reason: str) -> None:
    move_to(client, x, y)
    client.click()
    client._record("checkpoint", {"name": reason, "x": x, "y": y})


def type_text(client: QmpClient, text: str, delay: float) -> None:
    qcodes = {" ": "spc", "-": "minus", "_": "shift-minus"}
    for char in text:
        qcode = qcodes.get(char, char.lower())
        if len(qcode) != 1 and qcode != "shift-minus":
            client.key(qcode)
        elif qcode == "shift-minus":
            client.key("shift-minus")
        else:
            client.key(qcode)
        if delay:
            time.sleep(delay)


def run_scenario(client: QmpClient, args: argparse.Namespace) -> None:
    pause(client, args.ready_wait, "wait for Weston and Chromium")

    click_at(client, 280, 184, "run-selftest")
    pause(client, 2.0, "T4 timer and Promise completion")

    click_at(client, 340, 657, "focus-text-input")
    type_text(client, "hello x-kernel", args.key_delay)
    pause(client, 1.0, "input echo update")

    click_at(client, 289, 771, "real-click-plus-one")
    pause(client, args.interaction_hold, "capture interaction state")

    # The real-click button retains focus after the pointer click.  Tab moves
    # to the layout link and Enter follows it through Chromium navigation.
    client.key("tab")
    client.key("ret")
    pause(client, args.navigation_wait, "layout navigation and load listener")
    client.key("pgdn")
    client.key("pgdn")
    pause(client, args.layout_hold, "CSS verdict after scrolling")

    if not args.skip_index:
        # Exercise the browser back path, then use the native form controls on
        # the static entry page.  These controls require no page-specific JS.
        client.key("alt-left")
        pause(client, args.back_wait, "return to index page")
        click_at(client, 790, 584, "index-name-input")
        type_text(client, "!", args.key_delay)
        click_at(client, 671, 615, "index-graphics-checkbox")
        pause(client, 2.0, "index native controls")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="QEMU QMP Unix socket")
    parser.add_argument("--output", required=True, type=Path, help="JSONL event log")
    parser.add_argument("--connect-timeout", type=float, default=300.0)
    parser.add_argument("--ready-wait", type=float, default=90.0)
    parser.add_argument("--interaction-hold", type=float, default=25.0)
    parser.add_argument("--navigation-wait", type=float, default=8.0)
    parser.add_argument("--layout-hold", type=float, default=18.0)
    parser.add_argument("--back-wait", type=float, default=8.0)
    parser.add_argument("--key-delay", type=float, default=0.08)
    parser.add_argument("--skip-index", action="store_true")
    parser.add_argument("--force-hmp", action="store_true",
                        help="通过 QMP human-monitor-command 使用 HMP 输入兼容接口")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    client = QmpClient(args.socket, args.output, force_hmp=args.force_hmp)
    try:
        client.connect(args.connect_timeout)
        run_scenario(client, args)
        client._record("result", {"ok": True})
        return 0
    except (OSError, QmpError) as exc:
        client._record("result", {"ok": False, "error": str(exc)})
        print(f"qmp_input: {exc}", file=sys.stderr)
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
