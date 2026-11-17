#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert a T490 Chromium console log into a compact JSONL event ledger.

The guest log is intentionally kept as the source of truth.  This converter
does not infer success from a PID or from a renderer command line; it only
normalizes events that are already present in the log so later gates can be
recomputed without hand editing evidence.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Iterable


PREFIX_RE = re.compile(
    r"^\[\s*(?P<mono>[0-9]+(?:\.[0-9]+)?)\s+(?P<cpu>\d+):(?P<tid>\d+)\s+(?P<module>[^\]]+)\]\s*(?P<body>.*)$"
)
CHROME_PREFIX_RE = re.compile(r"^\[(?P<pid>\d+):(?P<tid>\d+):")
KV_RE = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>\"[^\"]*\"|\S+)")
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def _decode_value(value: str) -> Any:
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if value in {"true", "false"}:
        return value == "true"
    if value in {"null", "None"}:
        return None
    try:
        return int(value, 0)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def _fields(body: str) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for match in KV_RE.finditer(body):
        fields[match.group("key")] = _decode_value(match.group("value"))
    return fields


def _event_for(body: str) -> str | None:
    if "SANDBOX_ZYGOTE_FORK_FDS" in body:
        return "process.fork"
    if "SANDBOX_EXEC " in body:
        return "process.exec"
    if "SANDBOX_EXIT " in body:
        return "process.exit"
    if "CHROMIUM_KILL " in body:
        return "process.kill"
    if "SANDBOX_PREAD_HTML" in body:
        return "navigation.response-read"
    if "FileURLLoader::Start" in body:
        return "navigation.response-start"
    if "DocumentLoader" in body:
        return "navigation.document-loader"
    if "DidCommitNavigation" in body:
        return "navigation.document-commit"
    if "CHROMIUM_SCM_RIGHTS" in body:
        return "ipc.scm-rights"
    if "CHROMIUM_IPCZ_ACCEPT" in body:
        return "ipc.ipcz-accept-parcel"
    if "CHROMIUM_IPCZ_FRAME" in body:
        return "ipc.ipcz-frame"
    if "CHROMIUM_UNIX_IPC" in body:
        return "ipc.unix"
    if "CHROMIUM_DGRAM_" in body:
        return "ipc.unix-dgram"
    if "CHROMIUM_EPOLL_WAIT" in body:
        return "ipc.epoll-wait"
    if "CHROMIUM_EPOLL " in body:
        return "ipc.epoll-ctl"
    if "CHROMIUM_FUTEX_" in body:
        return "ipc.futex"
    if "CHROMIUM_FRAGMENT_FAULT" in body:
        return "memory.shared-fragment-fault"
    if "Terminating current process after" in body:
        return "renderer.connection-timeout"
    if "frame-created" in body or "FrameSink" in body:
        return "compositor.frame"
    if "buffer-attach" in body or "wl_surface.attach" in body:
        return "wayland.buffer-attach"
    if "wl_surface.commit" in body:
        return "wayland.commit"
    if body.startswith("[mpdiag]") and "MP_" in body:
        return "diagnostic.marker"
    return None


def _role(body: str, fields: dict[str, Any]) -> str | None:
    role = fields.get("role")
    if isinstance(role, str):
        return role
    if "--type=renderer" in body:
        return "renderer"
    if "--type=zygote" in body:
        return "zygote"
    if "--type=utility" in body:
        return "utility"
    if "FileURLLoader" in body or "browser" in body.lower():
        return "browser"
    return None


def iter_events(lines: Iterable[str]) -> Iterable[dict[str, Any]]:
    for line_number, raw_line in enumerate(lines, start=1):
        line = ANSI_RE.sub("", raw_line.rstrip("\r\n"))
        match = PREFIX_RE.match(line)
        if match:
            body = match.group("body")
            fields = _fields(body)
            event = _event_for(body)
            if event is None:
                continue
            item: dict[str, Any] = {
                "timestamp_monotonic": float(match.group("mono")),
                "process_role": _role(body, fields),
                "pid": fields.get("pid"),
                "ppid": fields.get("ppid"),
                "tid": int(match.group("tid")),
                "event": event,
                "status": fields.get("status") or fields.get("result"),
                "error": fields.get("error") or fields.get("err"),
                "line": line_number,
                "raw": line,
            }
            for key in (
                "navigation_id",
                "frame_tree_node_id",
                "document_id",
                "mojo_endpoint_or_pipe_id",
                "shared_object_id_or_file_object_id",
                "fd",
                "epfd",
                "child_pid",
                "parent_pid",
                "bytes",
                "ancillary",
                "ready",
                "rows",
                "op",
                "target",
                "new_fd",
                "signo",
                "sublink",
                "sequence",
                "subparcel",
                "num_subparcels",
                "buffer_id",
                "offset",
                "size",
                "wire_len",
                "payload_len",
                "route_or_id",
                "path",
                "page",
                "paddr",
                "len",
            ):
                if key in fields:
                    item[key] = fields[key]
            yield item
            continue

        # Chromium's own logging format has wall-clock timestamps and does
        # not carry the x-kernel monotonic prefix.  Preserve these high-value
        # lifecycle/navigation records with a null monotonic timestamp.
        event = _event_for(line)
        if event is not None:
            chrome_match = CHROME_PREFIX_RE.match(line)
            yield {
                "timestamp_monotonic": None,
                "process_role": "renderer" if event.startswith("renderer.") else "browser",
                "pid": int(chrome_match.group("pid")) if chrome_match else None,
                "ppid": None,
                "tid": int(chrome_match.group("tid")) if chrome_match else None,
                "event": event,
                "status": None,
                "error": None,
                "line": line_number,
                "raw": line,
            }
            continue

        # Keep the machine-readable MP_* markers even when they are not
        # prefixed by the kernel logger.
        if "MP_" in line or "SCORE_PAGE_" in line:
            yield {
                "timestamp_monotonic": None,
                "process_role": None,
                "pid": None,
                "ppid": None,
                "tid": None,
                "event": "diagnostic.marker",
                "status": None,
                "error": None,
                "line": line_number,
                "raw": line,
            }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="guest console.log")
    parser.add_argument("output", type=Path, help="JSONL output path")
    args = parser.parse_args()

    if not args.log.is_file():
        parser.error(f"log does not exist: {args.log}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("r", encoding="utf-8", errors="replace") as source, args.output.open(
        "w", encoding="utf-8", newline="\n"
    ) as dest:
        for item in iter_events(source):
            dest.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
