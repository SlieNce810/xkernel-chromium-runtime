#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Implement automatic SO_PASSCRED for Unix datagram and stream sockets."""
from __future__ import annotations

from pathlib import Path

root = Path.home() / "x-kernel"


def patch_file(
    relative: str,
    old: str,
    new: str,
    label: str,
    expected_count: int = 1,
) -> None:
    path = root / relative
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"[skip] {label}")
        return
    count = text.count(old)
    if count != expected_count:
        raise SystemExit(
            f"[FATAL] {label}: expected {expected_count} anchors, found {count}"
        )
    path.write_text(text.replace(old, new, expected_count), encoding="utf-8")
    print(f"[ok] {label}")


patch_file(
    "net/knet/src/unix/dgram.rs",
    "use alloc::{boxed::Box, sync::Arc, vec::Vec};\n",
    "use alloc::{boxed::Box, sync::Arc, vec::Vec};\nuse core::sync::atomic::{AtomicBool, Ordering};\n",
    "imported datagram SO_PASSCRED state primitives",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "    AncillaryData, ConnectOptions, RecvFlags, RecvOptions, SendOptions, SocketAddrEx,\n    general::GeneralOptions,\n",
    "    AncillaryData, ConnectOptions, KernelAncillaryData, RecvFlags, RecvOptions, SendOptions, SocketAddrEx,\n    general::GeneralOptions,\n",
    "imported automatic credential ancillary type for datagrams",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "struct Datagram {\n    data: Vec<u8>,\n    ancillary: Vec<AncillaryData>,\n    sender: UnixAddr,\n}\n",
    "struct Datagram {\n    data: Vec<u8>,\n    ancillary: Vec<AncillaryData>,\n    sender: UnixAddr,\n    sender_credentials: UnixCredentials,\n}\n",
    "stored sender credentials with Unix datagrams",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "    options: GeneralOptions,\n    pid: u32,\n",
    "    options: GeneralOptions,\n    pass_credentials: AtomicBool,\n    pid: u32,\n",
    "added SO_PASSCRED state to datagram sockets",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "            options: GeneralOptions::default(),\n            pid,\n",
    "            options: GeneralOptions::default(),\n            pass_credentials: AtomicBool::new(false),\n            pid,\n",
    "initialized datagram SO_PASSCRED state",
    expected_count=2,
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "            O::PassCredentials(_) => {}\n            O::PeerCredentials(cred) => {\n",
    "            O::PassCredentials(enabled) => {\n                **enabled = self.pass_credentials.load(Ordering::Acquire);\n            }\n            O::PeerCredentials(cred) => {\n",
    "implemented datagram SO_PASSCRED getsockopt",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "            O::PassCredentials(_) => {}\n            _ => return Ok(OptionHandled::No),\n",
    "            O::PassCredentials(enabled) => {\n                self.pass_credentials.store(*enabled, Ordering::Release);\n            }\n            _ => return Ok(OptionHandled::No),\n",
    "implemented datagram SO_PASSCRED setsockopt",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "        let len = message.len();\n        let packet = Datagram {\n            data: message,\n            ancillary: options.ancillary,\n            sender: self.local_addr.read().clone(),\n        };\n\n        let connected = self.peer.read();\n        if let Some(addr) = options.to {\n            let addr = addr.into_unix()?;\n            let cred = kprocess::current_cred();\n",
    "        let len = message.len();\n        let caller_cred = kprocess::current_cred();\n        let sender_credentials = UnixCredentials {\n            pid: kprocess::current_user_thread().pid(),\n            uid: caller_cred.euid(),\n            gid: caller_cred.egid(),\n        };\n        let packet = Datagram {\n            data: message,\n            ancillary: options.ancillary,\n            sender: self.local_addr.read().clone(),\n            sender_credentials,\n        };\n\n        let connected = self.peer.read();\n        if let Some(addr) = options.to {\n            let addr = addr.into_unix()?;\n            let cred = caller_cred;\n",
    "captured current-process credentials on datagram send",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "                data,\n                ancillary,\n                sender,\n            } = match rx.try_recv() {\n",
    "                data,\n                ancillary,\n                sender,\n                sender_credentials,\n            } = match rx.try_recv() {\n",
    "read stored sender credentials on datagram receive",
)
patch_file(
    "net/knet/src/unix/dgram.rs",
    "            if let Some(dst) = options.ancillary.as_mut() {\n                dst.extend(ancillary);\n            }\n",
    "            if let Some(dst) = options.ancillary.as_mut() {\n                if self.pass_credentials.load(Ordering::Acquire) {\n                    dst.push(Box::new(KernelAncillaryData::Credentials(sender_credentials)));\n                }\n                dst.extend(ancillary);\n            }\n",
    "delivered SCM_CREDENTIALS when datagram receiver enables SO_PASSCRED",
)

patch_file(
    "net/knet/src/unix/stream.rs",
    "use alloc::{boxed::Box, sync::Arc};\nuse core::sync::atomic::Ordering;\n",
    "use alloc::{boxed::Box, sync::Arc, vec::Vec};\nuse core::sync::atomic::{AtomicBool, Ordering};\n",
    "imported stream SO_PASSCRED state primitives",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "use alloc::{boxed::Box, sync::Arc, vec::Vec};\n",
    "use alloc::{boxed::Box, sync::Arc};\n",
    "removed unused stream credential Vec import",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "    ConnectOptions, RecvOptions, SendOptions, Shutdown,\n    general::GeneralOptions,\n",
    "    ConnectOptions, KernelAncillaryData, RecvOptions, SendOptions, Shutdown,\n    general::GeneralOptions,\n",
    "imported automatic credential ancillary type for streams",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "    options: GeneralOptions,\n    pid: u32,\n",
    "    options: GeneralOptions,\n    pass_credentials: AtomicBool,\n    pid: u32,\n",
    "added SO_PASSCRED state to stream sockets",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "            options: GeneralOptions::default(),\n            pid,\n",
    "            options: GeneralOptions::default(),\n            pass_credentials: AtomicBool::new(false),\n            pid,\n",
    "initialized stream SO_PASSCRED state",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "            O::PassCredentials(_) => {}\n            O::PeerCredentials(cred) => {\n",
    "            O::PassCredentials(enabled) => {\n                **enabled = self.pass_credentials.load(Ordering::Acquire);\n            }\n            O::PeerCredentials(cred) => {\n",
    "implemented stream SO_PASSCRED getsockopt",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "            O::PassCredentials(_) => {}\n            _ => return Ok(OptionHandled::No),\n",
    "            O::PassCredentials(enabled) => {\n                self.pass_credentials.store(*enabled, Ordering::Release);\n            }\n            _ => return Ok(OptionHandled::No),\n",
    "implemented stream SO_PASSCRED setsockopt",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "        let mut ancillary = options.ancillary;\n        let mut ancillary_published = ancillary.is_empty();\n",
    "        let mut ancillary = options.ancillary;\n        let caller_cred = kprocess::current_cred();\n        ancillary.push(Box::new(KernelAncillaryData::Credentials(UnixCredentials {\n            pid: kprocess::current_user_thread().pid(),\n            uid: caller_cred.euid(),\n            gid: caller_cred.egid(),\n        })));\n        let mut ancillary_published = false;\n",
    "captured current-process credentials on stream send",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "                    if let Some(out) = ancillary_out.as_mut()\n                        && let Some(mut received) = chan.incoming_ancillary.lock().pop_front()\n                    {\n                        out.append(&mut received);\n                    }\n",
    "                    if let Some(mut received) = chan.incoming_ancillary.lock().pop_front() {\n                        if !self.pass_credentials.load(Ordering::Acquire) {\n                            received.retain(|item| {\n                                !matches!(\n                                    item.as_ref().downcast_ref::<KernelAncillaryData>(),\n                                    Some(KernelAncillaryData::Credentials(_)),\n                                )\n                            });\n                        }\n                        if let Some(out) = ancillary_out.as_mut() {\n                            out.append(&mut received);\n                        }\n                    }\n",
    "delivered automatic stream credentials only to SO_PASSCRED receivers",
)

print("[done] Unix SOCK_DGRAM/SOCK_STREAM SO_PASSCRED now yields kernel SCM_CREDENTIALS")
