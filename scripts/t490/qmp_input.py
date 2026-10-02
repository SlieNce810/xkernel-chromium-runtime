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
import re
import socket
import sys
import time
from pathlib import Path
from typing import Any, Iterable


class QmpError(RuntimeError):
    """A QMP command returned an error or the monitor closed."""


class QmpClient:
    def __init__(self, path: str, output: Path, force_hmp: bool = False,
                 qmp_send_key: bool = False, absolute_pointer: bool = False,
                 input_target: str = "auto") -> None:
        self.path = path
        self.output = output
        self.force_hmp = force_hmp
        self.qmp_send_key = qmp_send_key
        self.absolute_pointer = absolute_pointer
        self.input_target = input_target
        self.input_target_candidates: list[str] = []
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

    def connect(self, timeout: float, mouse_index: int = -1) -> None:
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
                for console_path in ("/backend/console[0]", "/backend/console[1]"):
                    try:
                        qom = self.command("qom-get", {"path": console_path,
                                                         "property": "device"})
                        self._record("console-device", {"path": console_path, "value": qom})
                        device_path = qom.get("return")
                        if isinstance(device_path, str):
                            for prop in ("type", "id", "canonical-path"):
                                try:
                                    detail = self.command("qom-get", {"path": device_path,
                                                                        "property": prop})
                                    self._record("console-device-property",
                                                 {"path": device_path, "property": prop,
                                                  "value": detail})
                                    value = detail.get("return")
                                    if isinstance(value, str):
                                        self.input_target_candidates.append(value)
                                except QmpError as exc:
                                    self._record("console-device-property-error",
                                                 {"path": device_path, "property": prop,
                                                  "error": str(exc)})
                    except QmpError as exc:
                        self._record("console-device-error", {"path": console_path,
                                                               "error": str(exc)})
                # QEMU keeps a selected active mouse for HMP compatibility.
                # Record the inventory and select the virtio mouse explicitly;
                # this is harmless for QMP-only mode and removes an otherwise
                # implicit display-routing choice from the evidence.
                try:
                    mice = self.command("query-mice")
                    self._record("mouse-query", mice)
                    inventory = self.hmp("info mice")
                    self._record("mouse-inventory", inventory)
                    selected = mouse_index
                    if selected < 0 and self.absolute_pointer:
                        entries = mice.get("return", [])
                        if isinstance(entries, list):
                            absolute = next((item for item in entries
                                              if item.get("absolute") is True), None)
                            if isinstance(absolute, dict):
                                selected = int(absolute["index"])
                    if selected < 0:
                        entries = mice.get("return", [])
                        if isinstance(entries, list):
                            current = next((item for item in entries
                                             if item.get("current") is True), None)
                            chosen = current or (entries[0] if entries else None)
                            if isinstance(chosen, dict):
                                selected = int(chosen["index"])
                    if selected < 0:
                        listing = str(inventory.get("return", ""))
                        match = re.search(r"Mouse #(\d+)", listing)
                        if match:
                            selected = int(match.group(1))
                    if selected < 0:
                        raise QmpError("info mice returned no selectable mouse")
                    self.hmp(f"mouse_set {selected}")
                    self._record("mouse-selected", {"index": selected})
                except QmpError as exc:
                    self._record("mouse-selection-error", {"error": str(exc)})
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

    def input_events(self, events: list[dict[str, Any]]) -> None:
        if self.input_target == "auto":
            candidates = list(self.input_target_candidates)
            candidates.extend(["virtio-gpu", "virtio-gpu-pci", "display0", "video0", ""])
        else:
            candidates = [self.input_target]
        seen: set[str] = set()
        last_error: QmpError | None = None
        for target in candidates:
            if target in seen:
                continue
            seen.add(target)
            arguments: dict[str, Any] = {"events": events}
            if target:
                arguments["device"] = target
            try:
                self.command("input-send-event", arguments)
                if self.input_target == "auto":
                    self.input_target = target
                    self._record("input-target-selected", {"target": target})
                return
            except QmpError as exc:
                last_error = exc
                self._record("input-target-error", {"target": target, "error": str(exc)})
        raise last_error or QmpError("no input-send-event target")

    def event(self, value: dict[str, Any]) -> None:
        self.input_events([value])

    def key(self, qcode: str) -> None:
        if self.qmp_send_key:
            if qcode == "alt-left":
                self.command("send-key", {"keys": [
                    {"type": "qcode", "data": "alt"},
                    {"type": "qcode", "data": "left"},
                ]})
                self._record("action", {"op": "key", "qcode": qcode,
                                         "transport": "send-key-chord"})
                return
            self.command("send-key", {"keys": [{"type": "qcode", "data": qcode}]})
            self._record("action", {"op": "key", "qcode": qcode, "transport": "send-key"})
            return
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

    def absolute_pixel(self, x: int, y: int) -> None:
        if not self.absolute_pointer:
            raise QmpError("absolute pointer mode is disabled")
        x_value = max(0, min(0x7FFF, round(x * 0x7FFF / 1280)))
        y_value = max(0, min(0x7FFF, round(y * 0x7FFF / 800)))
        self.input_events([
            {"type": "abs", "data": {"axis": "x", "value": x_value}},
            {"type": "abs", "data": {"axis": "y", "value": y_value}},
        ])
        self._record("action", {"op": "absolute", "x": x, "y": y,
                                 "qemu_x": x_value, "qemu_y": y_value,
                                 "transport": "qmp"})


def pause(client: QmpClient, seconds: float, reason: str) -> None:
    client._record("sleep", {"seconds": seconds, "reason": reason})
    time.sleep(seconds)


def move_to(client: QmpClient, x: int, y: int) -> None:
    if client.absolute_pointer:
        client.absolute_pixel(x, y)
        return
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
    parser.add_argument("--qmp-send-key", action="store_true",
                        help="用 QMP send-key 命令发送键盘事件")
    parser.add_argument("--absolute-pointer", action="store_true",
                        help="使用 virtio-tablet 的 QMP 绝对坐标")
    parser.add_argument("--input-target", default="auto",
                        help="input-send-event 的 QEMU display device 路由名，auto 自动探测")
    parser.add_argument("--mouse-index", type=int, default=-1,
                        help="HMP active mouse index，-1 表示从 info mice 自动选择")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    client = QmpClient(args.socket, args.output, force_hmp=args.force_hmp,
                       qmp_send_key=args.qmp_send_key,
                       absolute_pointer=args.absolute_pointer,
                       input_target=args.input_target)
    try:
        client.connect(args.connect_timeout, mouse_index=args.mouse_index)
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
