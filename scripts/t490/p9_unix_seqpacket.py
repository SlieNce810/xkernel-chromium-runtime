#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Route pathname AF_UNIX SOCK_SEQPACKET sockets for eudev control IPC.

The existing socketpair path already creates record-oriented DgramTransport
endpoints. This adds pathname socket creation to the existing connection,
listen, and accept transport used by eudev control. The current transport uses
the stream channel for pathname sockets; this is a targeted control-protocol
bridge, not evidence that general record-boundary semantics are complete.
"""
from __future__ import annotations

from pathlib import Path

path = Path.home() / "x-kernel/posix/net/src/socket.rs"
text = path.read_text(encoding="utf-8")
anchor = """        (AF_UNIX, SOCK_STREAM) => {
            // Unix domain stream socket
            knet::Socket::Unix(Box::new(UnixDomainSocket::new(StreamTransport::new(pid))))
        }
        (AF_UNIX, SOCK_DGRAM) => {
"""
addition = """        (AF_UNIX, SOCK_STREAM) => {
            // Unix domain stream socket
            knet::Socket::Unix(Box::new(UnixDomainSocket::new(StreamTransport::new(pid))))
        }
        (AF_UNIX, SOCK_SEQPACKET) => {
            // The current pathname listener/accept implementation is the
            // connection-oriented transport used by eudev control sockets.
            knet::Socket::Unix(Box::new(UnixDomainSocket::new(StreamTransport::new(pid))))
        }
        (AF_UNIX, SOCK_DGRAM) => {
"""
if addition in text:
    print("[skip] AF_UNIX SOCK_SEQPACKET route already applied")
elif text.count(anchor) == 1:
    path.write_text(text.replace(anchor, addition, 1), encoding="utf-8")
    print("[ok] pathname AF_UNIX SOCK_SEQPACKET route added")
else:
    raise SystemExit(f"[FATAL] expected one AF_UNIX socket dispatch anchor in {path}")
