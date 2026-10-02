#!/usr/bin/env python3
"""Drive the three test pages through Chromium's official DevTools Protocol.

This is the browser-level fallback used when QEMU's display input route cannot
feed the x-kernel virtio-input queue.  It uses the documented Input and Runtime
domains, records every command and DOM checkpoint, and never changes page code.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


class CdpError(RuntimeError):
    pass


class Ws:
    def __init__(self, url: str, output: Path) -> None:
        parsed = urlparse(url)
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port or 80
        self.path = parsed.path or "/"
        self.output = output
        self.sock: socket.socket | None = None
        self.buffer = b""
        self.next_id = 0

    def record(self, kind: str, value: Any) -> None:
        self.output.parent.mkdir(parents=True, exist_ok=True)
        with self.output.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.time(), "kind": kind, "value": value},
                                ensure_ascii=False, sort_keys=True) + "\n")

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {self.path} HTTP/1.1\r\nHost: {self.host}:{self.port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
        self.sock.sendall(request)
        response = b""
        while b"\r\n\r\n" not in response:
            response += self.sock.recv(4096)
        if not response.startswith(b"HTTP/1.1 101"):
            raise CdpError(f"websocket handshake failed: {response[:200]!r}")
        self.record("connected", {"url": f"ws://{self.host}:{self.port}{self.path}"})

    def send_frame(self, payload: bytes) -> None:
        assert self.sock is not None
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        length = len(masked)
        if length < 126:
            header = bytes([0x81, 0x80 | length])
        elif length <= 0xFFFF:
            header = bytes([0x81, 0x80 | 126]) + struct.pack(">H", length)
        else:
            header = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", length)
        self.sock.sendall(header + mask + masked)

    def recv_frame(self) -> tuple[int, bytes]:
        assert self.sock is not None
        while len(self.buffer) < 2:
            self.buffer += self.sock.recv(65536)
        first, second = self.buffer[0], self.buffer[1]
        self.buffer = self.buffer[2:]
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            while len(self.buffer) < 2:
                self.buffer += self.sock.recv(65536)
            length = struct.unpack(">H", self.buffer[:2])[0]
            self.buffer = self.buffer[2:]
        elif length == 127:
            while len(self.buffer) < 8:
                self.buffer += self.sock.recv(65536)
            length = struct.unpack(">Q", self.buffer[:8])[0]
            self.buffer = self.buffer[8:]
        while len(self.buffer) < length:
            self.buffer += self.sock.recv(65536)
        data, self.buffer = self.buffer[:length], self.buffer[length:]
        return opcode, data

    def command(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.next_id += 1
        request: dict[str, Any] = {"id": self.next_id, "method": method}
        if params:
            request["params"] = params
        self.record("tx", request)
        self.send_frame(json.dumps(request, ensure_ascii=False).encode())
        while True:
            opcode, data = self.recv_frame()
            if opcode == 0x9:
                self.send_frame(data)
                continue
            if opcode != 0x1:
                continue
            response = json.loads(data.decode("utf-8"))
            self.record("rx", response)
            if response.get("id") == self.next_id:
                if "error" in response:
                    raise CdpError(json.dumps(response["error"], ensure_ascii=False))
                return response

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close()
            self.sock = None


def http_json(host: str, port: int, path: str) -> Any:
    sock = socket.create_connection((host, port), timeout=5)
    sock.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n".encode())
    data = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    sock.close()
    body = data.split(b"\r\n\r\n", 1)[-1]
    return json.loads(body.decode("utf-8"))


def wait_target(host: str, port: int, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            targets = http_json(host, port, "/json/list")
            for target in targets:
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                    return target
        except (OSError, ValueError, CdpError) as exc:
            last = exc
        time.sleep(1)
    raise CdpError(f"CDP target timeout: {last}")


class Driver:
    def __init__(self, cdp: Ws, output: Path) -> None:
        self.cdp = cdp
        self.output = output

    def checkpoint(self, name: str, value: Any) -> None:
        self.cdp.record("checkpoint", {"name": name, "value": value})

    def evaluate(self, expression: str) -> Any:
        response = self.cdp.command("Runtime.evaluate", {
            "expression": expression,
            "returnByValue": True,
            "awaitPromise": True,
            "userGesture": True,
        })
        result = response.get("result", {}).get("result", {})
        return result.get("value")

    def state(self) -> Any:
        return self.evaluate("""(() => ({
          url: location.href,
          title: document.title,
          kb: document.getElementById('kb')?.value ?? null,
          echo: document.getElementById('kb-echo')?.textContent ?? null,
          clicks: document.getElementById('click-n')?.textContent ?? null,
          core: document.getElementById('verdict')?.textContent ?? null,
          fs: document.getElementById('fs-verdict')?.textContent ?? null,
          layoutRows: ['C1','C2','C3','C4','C5','C6'].map(id =>
            document.getElementById('s-' + id)?.textContent ?? null)
        }))()""")

    def mouse_click(self, x: int, y: int, name: str) -> None:
        self.cdp.command("Input.dispatchMouseEvent", {
            "type": "mouseMoved", "x": x, "y": y, "button": "none"})
        self.cdp.command("Input.dispatchMouseEvent", {
            "type": "mousePressed", "x": x, "y": y,
            "button": "left", "buttons": 1, "clickCount": 1})
        self.cdp.command("Input.dispatchMouseEvent", {
            "type": "mouseReleased", "x": x, "y": y,
            "button": "left", "buttons": 0, "clickCount": 1})
        self.checkpoint(name, {"x": x, "y": y})

    def key(self, key: str, code: str, text: str = "") -> None:
        self.cdp.command("Input.dispatchKeyEvent", {
            "type": "keyDown", "key": key, "code": code,
            "text": text, "unmodifiedText": text})
        self.cdp.command("Input.dispatchKeyEvent", {
            "type": "keyUp", "key": key, "code": code})

    def type_text(self, value: str) -> None:
        for char in value:
            if char == " ":
                self.key(" ", "Space", " ")
            elif char == "-":
                self.key("-", "Minus", "-")
            else:
                self.key(char, "Key" + char.upper(), char)


def run(args: argparse.Namespace) -> None:
    target = wait_target(args.host, args.port, args.connect_timeout)
    ws_url = target["webSocketDebuggerUrl"].replace("localhost", args.host)
    ws_url = ws_url.replace(":9222/", f":{args.port}/")
    cdp = Ws(ws_url, args.output)
    cdp.connect()
    driver = Driver(cdp, args.output)
    time.sleep(args.ready_wait)

    driver.checkpoint("initial", driver.state())
    driver.mouse_click(280, 184, "run-selftest")
    time.sleep(2)
    driver.checkpoint("selftest", driver.state())
    driver.mouse_click(340, 657, "focus-text-input")
    driver.type_text("hello x-kernel")
    time.sleep(1)
    driver.checkpoint("keyboard-echo", driver.state())
    driver.mouse_click(289, 771, "real-click-plus-one")
    time.sleep(2)
    driver.checkpoint("mouse-counter", driver.state())

    driver.key("Tab", "Tab")
    driver.key("Enter", "Enter", "\r")
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        state = driver.state()
        if state and "layout.html" in state.get("url", ""):
            break
        time.sleep(1)
    driver.cdp.command("Input.dispatchMouseEvent", {
        "type": "mouseWheel", "x": 640, "y": 400, "deltaY": 1200})
    driver.cdp.command("Input.dispatchMouseEvent", {
        "type": "mouseWheel", "x": 640, "y": 400, "deltaY": 1200})
    time.sleep(3)
    driver.checkpoint("layout", driver.state())

    driver.cdp.command("Page.getNavigationHistory")
    driver.cdp.command("Input.dispatchKeyEvent", {
        "type": "keyDown", "key": "Alt", "code": "AltLeft", "modifiers": 1})
    driver.cdp.command("Input.dispatchKeyEvent", {
        "type": "keyDown", "key": "ArrowLeft", "code": "ArrowLeft", "modifiers": 1})
    driver.cdp.command("Input.dispatchKeyEvent", {
        "type": "keyUp", "key": "ArrowLeft", "code": "ArrowLeft", "modifiers": 1})
    driver.cdp.command("Input.dispatchKeyEvent", {
        "type": "keyUp", "key": "Alt", "code": "AltLeft"})
    time.sleep(1)
    driver.checkpoint("back", driver.state())
    driver.mouse_click(790, 584, "index-name-input")
    driver.type_text("!")
    driver.mouse_click(671, 615, "index-graphics-checkbox")
    driver.checkpoint("index-controls", driver.state())
    driver.cdp.record("result", {"ok": True})
    cdp.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=61006)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--connect-timeout", type=float, default=300)
    parser.add_argument("--ready-wait", type=float, default=90)
    args = parser.parse_args()
    try:
        run(args)
        return 0
    except (OSError, ValueError, CdpError) as exc:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.time(), "kind": "result",
                                 "value": {"ok": False, "error": str(exc)}},
                                ensure_ascii=False) + "\n")
        print(f"cdp_input: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
