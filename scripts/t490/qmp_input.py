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
import os
import re
import socket
import sys
import time
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse


class QmpError(RuntimeError):
    """A QMP command returned an error or the monitor closed."""


def open_qmp_socket(path: str, timeout: float) -> socket.socket:
    """Open a QMP endpoint.

    Production evidence uses a Unix socket.  ``tcp://host:port`` exists so the
    same client can be exercised against a fake QMP server on hosts (including
    Windows Python builds) without AF_UNIX support.
    """
    if path.startswith("tcp://"):
        parsed = urlparse(path)
        if not parsed.hostname or not parsed.port:
            raise QmpError(f"invalid TCP QMP endpoint: {path}")
        return socket.create_connection((parsed.hostname, parsed.port), timeout=timeout)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(path)
    return sock


class QmpClient:
    def __init__(self, path: str, output: Path, force_hmp: bool = False,
                 qmp_send_key: bool = False, absolute_pointer: bool = False,
                 no_clamp: bool = False,
                 input_target: str = "auto") -> None:
        self.path = path
        self.output = output
        self.force_hmp = force_hmp
        self.qmp_send_key = qmp_send_key
        self.absolute_pointer = absolute_pointer
        self.no_clamp = no_clamp
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
                sock = open_qmp_socket(
                    self.path, max(0.1, deadline - time.monotonic())
                )
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

    def screendump(self, host_path: Path, timeout: float = 30.0) -> Path:
        """Ask the QEMU monitor for a PPM and wait for the host file to settle."""
        host_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            host_path.unlink()
        except FileNotFoundError:
            pass
        self.command("screendump", {"filename": str(host_path)})
        deadline = time.monotonic() + timeout
        last_size = -1
        stable = 0
        while time.monotonic() < deadline:
            if host_path.exists():
                size = host_path.stat().st_size
                if size > 0 and size == last_size:
                    stable += 1
                    if stable >= 2:
                        self._record("screendump", {
                            "path": str(host_path),
                            "bytes": size,
                        })
                        return host_path
                else:
                    stable = 0
                last_size = size
            time.sleep(0.2)
        raise QmpError(f"screendump did not settle: {host_path}")

    def input_events(self, events: list[dict[str, Any]]) -> None:
        if self.input_target == "auto":
            event_types = {str(event.get("type", "")) for event in events}
            # A diagnostic QEMU command may inject stable input IDs and opt in
            # with QMP_STABLE_INPUT_IDS=1.  Keep the formal anonymous-device
            # path unchanged until that QEMU route is proven not to abort.
            stable_ids = os.environ.get("QMP_STABLE_INPUT_IDS", "0") == "1"
            if stable_ids and event_types <= {"key"}:
                preferred = ["xk-keyboard"]
            elif stable_ids and event_types <= {"rel", "abs", "btn"}:
                preferred = ["xk-mouse"]
            elif stable_ids:
                preferred = ["xk-keyboard", "xk-mouse"]
            else:
                preferred = []
            candidates = preferred + list(self.input_target_candidates)
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

    def key_chord(self, qcodes: list[str]) -> None:
        """Send a simultaneous modifier/key chord through the selected QMP path."""
        if self.qmp_send_key:
            self.command("send-key", {"keys": [{"type": "qcode", "data": code}
                                                 for code in qcodes]})
            self._record("action", {"op": "key-chord", "qcodes": qcodes,
                                     "transport": "send-key-chord"})
            return
        if self.force_hmp:
            self.hmp("sendkey " + "-".join(qcodes))
            self._record("action", {"op": "key-chord", "qcodes": qcodes,
                                     "transport": "hmp"})
            return
        # input-send-event has explicit key state, so press modifiers first and
        # release in reverse order. This keeps the path equivalent to a real
        # keyboard chord for QMP builds that do not implement send-key.
        for code in qcodes:
            self.event({"type": "key", "data": {"down": True,
                                                   "key": {"type": "qcode", "data": code}}})
        for code in reversed(qcodes):
            self.event({"type": "key", "data": {"down": False,
                                                   "key": {"type": "qcode", "data": code}}})
        self._record("action", {"op": "key-chord", "qcodes": qcodes,
                                 "transport": "qmp"})

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
    if client.no_clamp:
        # Weston/libweston 不把指针钳制在输出范围内：`rel(-2000)` 会把指针推到
        # (-2000,-2000)，之后所有点击都落在"没有 view"的位置，客户端收不到任何
        # 指针事件（scene-graph 显示客户端其实全屏在 (0,0)-(1280,800)）。
        # 所以这里按"Weston 启动时指针在 (0,0)"的已知初值做相对位移，不做钳制。
        client.relative("x", x)
        client.relative("y", y)
        return
    # 旧路径：假定 QEMU/合成器会把指针钳在左上角。仅在明确知道该前提成立时使用。
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
        if char == "!":
            client.key_chord(["shift", "1"])
            if delay:
                time.sleep(delay)
            continue
        qcode = qcodes.get(char, char.lower())
        if len(qcode) != 1 and qcode != "shift-minus":
            client.key(qcode)
        elif qcode == "shift-minus":
            client.key("shift-minus")
        else:
            client.key(qcode)
        if delay:
            time.sleep(delay)


def run_kbd_probe(client: QmpClient, args: argparse.Namespace) -> None:
    """键盘优先的真实输入探针。

    为什么要它：input-final-r1..r5 已经把 QMP → virtio-input → evdev →
    libinput/Weston 四段逐一验证通过，只有"Weston → Chromium 客户端"这一段
    无法用像素证明（点击后画面逐字节相同）。而那段失败有两个完全不同的原因：
    （a）Weston 根本没把事件投给客户端（焦点/激活问题，内核或 shell 层）；
    （b）投给了，但相对指针受 libinput 加速影响，坐标落点不是按钮。
    Tab/Enter 不需要任何坐标 —— 只要键盘链通，第一个可聚焦控件（interaction
    页 DOM 里就是「运行自检」按钮）就会被 Enter 触发，结论条变绿。所以这一轮
    的结果能唯一地区分 (a) 和 (b)。
    """
    shot_dir = args.shot_dir
    if shot_dir is None:
        raise SystemExit("--kbd-probe 需要 --shot-dir")
    shot_dir.mkdir(parents=True, exist_ok=True)

    client.screendump(shot_dir / "before-kbd.ppm")
    client._record("checkpoint", {"name": "kbd-before"})

    # 可选：先在窗口内点一下。desktop-shell 下，第一次点击常常被用来激活窗口
    # （只送到 shell，不投给客户端），不先把窗口"点活"，后面发键就全落空。
    if args.pre_click_x >= 0 and args.pre_click_y >= 0:
        click_at(client, args.pre_click_x, args.pre_click_y, "pre-click-activate")
        pause(client, args.kbd_settle, "window activation")
        client.screendump(shot_dir / "after-preclick.ppm")
        client._record("checkpoint", {"name": "kbd-after-preclick"})

    client.key("tab")
    pause(client, args.kbd_settle, "focus ring after Tab")
    client.screendump(shot_dir / "after-tab.ppm")
    client._record("checkpoint", {"name": "kbd-after-tab"})

    client.key("ret")
    pause(client, max(args.kbd_settle, 8.0), "self-test Promise completion")
    client.screendump(shot_dir / "after-enter.ppm")
    client._record("checkpoint", {"name": "kbd-after-enter"})

    if args.reset_x >= 0 and args.reset_y >= 0:
        click_at(client, args.reset_x, args.reset_y, "reset-after-enter")
        pause(client, args.kbd_settle, "verdict returns to idle")
        client.screendump(shot_dir / "after-reset.ppm")
        client._record("checkpoint", {"name": "kbd-after-reset"})


def run_scenario(client: QmpClient, args: argparse.Namespace) -> None:
    pause(client, args.ready_wait, "wait for Weston and Chromium")

    if args.kbd_probe:
        run_kbd_probe(client, args)
        if args.final_screenshot is not None:
            client.screendump(args.final_screenshot)
        return

    click_at(client, args.self_test_x, args.self_test_y, "run-selftest")
    pause(client, 2.0, "T4 timer and Promise completion")
    if args.shot_dir is not None:
        args.shot_dir.mkdir(parents=True, exist_ok=True)
        client.screendump(args.shot_dir / "after-selftest.ppm")
        client._record("checkpoint", {"name": "after-selftest"})
    # These switches are intentionally handled in the QMP driver rather than
    # by a page script.  They make the JavaScript-only and full-input rounds
    # share one parser while keeping the browser-side action real.
    if args.self_test_only:
        client._record("checkpoint", {"name": "stop-after-selftest"})
        return

    click_at(client, args.text_x, args.text_y, "focus-text-input")
    type_text(client, args.input_text, args.key_delay)
    pause(client, 1.0, "input echo update")

    click_at(client, args.click_x, args.click_y, "real-click-plus-one")
    pause(client, args.interaction_hold, "capture interaction state")

    if args.skip_layout_navigation:
        client._record("checkpoint", {"name": "stop-before-layout"})
        return

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
    parser.add_argument("--input-text", default="hello x-kernel")
    # 坐标默认值来自 measure_controls.py 对 r5 原始 PPM 的实测（1280×800）：
    #   「运行自检」#17456b 92x34，bbox=[226,178,317,211] → 中心 (271,194)
    #   「重置」    #57606a 64x34，bbox=[331,178,394,211] → 中心 (362,194)
    # 旧默认值 (280,184)/(137,194) 是把 report/68 §五 的人工目测当成标定结果，
    # 其中 (137,194) 落在按钮左侧 92 px 的空白区 —— r1..r5 的"点击零变化"就是它。
    parser.add_argument("--self-test-x", type=int, default=271)
    parser.add_argument("--self-test-y", type=int, default=194)
    parser.add_argument("--text-x", type=int, default=340)
    parser.add_argument("--text-y", type=int, default=657)
    parser.add_argument("--click-x", type=int, default=289)
    parser.add_argument("--click-y", type=int, default=771)
    parser.add_argument("--skip-index", action="store_true")
    parser.add_argument("--skip-layout-navigation", action="store_true",
                        help="停在 interaction 页（键鼠回显与 +1 验证），不跳转 layout")
    parser.add_argument("--self-test-only", action="store_true",
                        help="只点击 interaction 页的 JavaScript 自检按钮")
    parser.add_argument("--echo-after-selftest", action="store_true",
                        help="保留兼容参数；自检后继续执行输入回显场景")
    parser.add_argument("--kbd-echo", action="store_true",
                        help="保留兼容参数；键盘动作已由 QMP 事件日志记录")
    parser.add_argument("--force-hmp", action="store_true",
                        help="通过 QMP human-monitor-command 使用 HMP 输入兼容接口")
    parser.add_argument("--qmp-send-key", action="store_true",
                        help="用 QMP send-key 命令发送键盘事件")
    parser.add_argument("--no-clamp", action="store_true",
                        help="相对指针不做 -2000 钳制。Weston 不把指针钳在输出内，"
                             "钳制会把指针推到屏幕外，之后所有点击都落空")
    parser.add_argument("--absolute-pointer", action="store_true",
                        help="使用 virtio-tablet 的 QMP 绝对坐标")
    parser.add_argument("--input-target", default="auto",
                        help="input-send-event 的 QEMU display device 路由名，auto 自动探测")
    parser.add_argument("--setup-only", action="store_true",
                        help="只建立 QMP、配置可选端口转发并记录设备，不发送页面动作")
    parser.add_argument("--screenshot-only", type=Path, default=None,
                        help="只通过 QMP screendump 保存一张 PPM，不发送输入")
    parser.add_argument("--cdp-forward-port", type=int, default=0,
                        help="通过 QEMU user-net 将宿主端口转发到 guest Chromium 9222")
    parser.add_argument("--mouse-index", type=int, default=-1,
                        help="HMP active mouse index，-1 表示从 info mice 自动选择")
    parser.add_argument("--kbd-probe", action="store_true",
                        help="键盘优先探针：Tab 聚焦 → Enter 激活 →（可选）点「重置」，"
                             "每步一张 screendump，用来把键盘链与鼠标坐标问题分开")
    parser.add_argument("--shot-dir", type=Path, default=None,
                        help="键盘探针的截图目录")
    parser.add_argument("--kbd-settle", type=float, default=3.0,
                        help="键盘探针每步后等待秒数（默认 3）")
    parser.add_argument("--pre-click-x", type=int, default=-1,
                        help="键盘探针开始前先点击该坐标（用于把窗口激活/取得指针焦点）")
    parser.add_argument("--pre-click-y", type=int, default=-1)
    parser.add_argument("--reset-x", type=int, default=-1,
                        help="键盘探针末尾要点击的「重置」按钮 x（-1 表示不做指针复核）")
    parser.add_argument("--reset-y", type=int, default=-1)
    parser.add_argument("--final-screenshot", type=Path, default=None,
                        help="完成场景后通过 QMP screendump 保存最终 PPM")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    client = QmpClient(args.socket, args.output, force_hmp=args.force_hmp,
                       qmp_send_key=args.qmp_send_key,
                       absolute_pointer=args.absolute_pointer,
                       no_clamp=args.no_clamp,
                       input_target=args.input_target)
    try:
        client.connect(args.connect_timeout, mouse_index=args.mouse_index)
        if args.cdp_forward_port:
            response = client.hmp(
                f"hostfwd_add net0 tcp::{args.cdp_forward_port}-:9222"
            )
            client._record("cdp-forward", {"port": args.cdp_forward_port,
                                             "response": response})
        if args.screenshot_only is not None:
            client.screendump(args.screenshot_only)
            client._record("result", {"ok": True, "mode": "screenshot-only"})
            return 0
        if args.setup_only:
            client._record("result", {"ok": True, "mode": "setup-only"})
            return 0
        run_scenario(client, args)
        if args.final_screenshot is not None:
            client.screendump(args.final_screenshot)
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
