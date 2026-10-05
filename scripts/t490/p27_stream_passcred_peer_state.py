#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tie Unix stream automatic credentials to the receiving endpoint option."""
from __future__ import annotations

from pathlib import Path

root = Path.home() / "x-kernel"


def patch_file(relative: str, old: str, new: str, label: str) -> None:
    path = root / relative
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"[skip] {label}")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"[FATAL] {label}: expected one anchor, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[ok] {label}")


patch_file(
    "net/knet/src/unix/stream/channel.rs",
    "pub(super) struct StreamEndpoint {\n    pub(super) polls: StreamPollSets,\n",
    "pub(super) struct StreamEndpoint {\n    pub(super) polls: StreamPollSets,\n    pub(super) pass_credentials: AtomicBool,\n",
    "stored SO_PASSCRED on the receiving stream endpoint",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "use core::sync::atomic::{AtomicBool, Ordering};\n",
    "use core::sync::atomic::Ordering;\n",
    "removed stream-local SO_PASSCRED flag",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "    options: GeneralOptions,\n    pass_credentials: AtomicBool,\n    pid: u32,\n",
    "    options: GeneralOptions,\n    pid: u32,\n",
    "removed stream-local SO_PASSCRED field",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "            options: GeneralOptions::default(),\n            pass_credentials: AtomicBool::new(false),\n            pid,\n",
    "            options: GeneralOptions::default(),\n            pid,\n",
    "removed stream-local SO_PASSCRED initialization",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "                **enabled = self.pass_credentials.load(Ordering::Acquire);\n",
    "                **enabled = self.endpoint.pass_credentials.load(Ordering::Acquire);\n",
    "getsockopt reads peer-visible stream SO_PASSCRED option",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "                self.pass_credentials.store(*enabled, Ordering::Release);\n",
    "                self.endpoint.pass_credentials.store(*enabled, Ordering::Release);\n",
    "setsockopt updates the receiving stream endpoint",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "        let mut ancillary = options.ancillary;\n        let caller_cred = kprocess::current_cred();\n        ancillary.push(Box::new(KernelAncillaryData::Credentials(UnixCredentials {\n            pid: kprocess::current_user_thread().pid(),\n            uid: caller_cred.euid(),\n            gid: caller_cred.egid(),\n        })));\n        let mut ancillary_published = false;\n",
    "        let peer_pass_credentials = self\n            .channel\n            .lock()\n            .as_ref()\n            .is_some_and(|channel| channel.peer_endpoint.pass_credentials.load(Ordering::Acquire));\n        let mut ancillary = options.ancillary;\n        if peer_pass_credentials {\n            let caller_cred = kprocess::current_cred();\n            ancillary.push(Box::new(KernelAncillaryData::Credentials(UnixCredentials {\n                pid: kprocess::current_user_thread().pid(),\n                uid: caller_cred.euid(),\n                gid: caller_cred.egid(),\n            })));\n        }\n        let mut ancillary_published = ancillary.is_empty();\n",
    "send automatic stream credentials only when peer requested them",
)
patch_file(
    "net/knet/src/unix/stream.rs",
    "if !self.pass_credentials.load(Ordering::Acquire) {\n",
    "if !self.endpoint.pass_credentials.load(Ordering::Acquire) {\n",
    "filter automatic credentials based on local stream SO_PASSCRED",
)

print("[done] Unix stream auto credentials are delivered only to opted-in peers")
