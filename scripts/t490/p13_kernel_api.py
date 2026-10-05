#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Install minimal real inotify syscalls and NETLINK SO_PASSCRED support."""
from __future__ import annotations

from pathlib import Path
import shutil

root = Path.home() / "x-kernel"
scripts = Path.home() / "xk6/scripts/t490"


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


shutil.copyfile(scripts / "inotify.rs", root / "process/kfd_objects/src/inotify.rs")
shutil.copyfile(scripts / "inotify_syscalls.rs", root / "posix/fs/src/inotify.rs")
print("[ok] installed inotify object and syscall adapter")

patch_file(
    "process/kfd_objects/src/lib.rs",
    "pub mod eventfd;\n",
    "pub mod eventfd;\npub mod inotify;\n",
    "exported kfd_objects::inotify",
)
patch_file(
    "posix/fs/Cargo.toml",
    "kfd.workspace = true\n",
    "kfd.workspace = true\nkfd_objects.workspace = true\n",
    "added kfd_objects dependency to posix-fs",
)
patch_file(
    "posix/fs/src/lib.rs",
    "mod ioctl;\nmod metadata;\n",
    "mod ioctl;\nmod inotify;\nmod metadata;\n",
    "registered posix-fs inotify module",
)
patch_file(
    "posix/fs/src/lib.rs",
    "dir::*, fd_ops::*, io::*, ioctl::*, metadata::*, mount::*, namei::*, open::*, stat::*, sync::*,\n",
    "dir::*, fd_ops::*, io::*, ioctl::*, inotify::*, metadata::*, mount::*, namei::*, open::*, stat::*, sync::*,\n",
    "re-exported inotify syscall adapters",
)

patch_file(
    "core/ksyscall/src/dispatch.rs",
    "        // dummy fds\n        Sysno::fanotify_init\n",
    "        Sysno::inotify_init1 => sys_inotify_init1(uctx.arg0() as _),\n        Sysno::inotify_add_watch => sys_inotify_add_watch(\n            uctx.arg0() as _,\n            uctx.arg1().into(),\n            uctx.arg2() as _,\n        ),\n        Sysno::inotify_rm_watch => sys_inotify_rm_watch(uctx.arg0() as _, uctx.arg1() as _),\n\n        // dummy fds\n        Sysno::fanotify_init\n",
    "dispatched inotify syscalls",
)
patch_file(
    "core/ksyscall/src/dispatch.rs",
    "Sysno::fanotify_init\n        | Sysno::inotify_init1\n        | Sysno::userfaultfd",
    "Sysno::fanotify_init\n        | Sysno::userfaultfd",
    "removed inotify_init1 from unsupported syscall list",
)

patch_file(
    "posix/fs/src/io.rs",
    "use iov_iter::{IovSink, IovSource, iov_iter_dest, iov_iter_source};\n",
    "use iov_iter::{IovSink, IovSource, iov_iter_dest, iov_iter_source};\nuse kfd_objects::inotify::{notify_inode_event, IN_MODIFY};\n",
    "imported inode notification hook for file writes",
)
patch_file(
    "posix/fs/src/io.rs",
    "    let mut src = IoSourceAdapter(src);\n    let mut iter = iov_iter_source(&mut src);\n    file.write_iter_from(&mut iter, pos)\n}\n\nfn write_file_from_io(",
    "    let mut src = IoSourceAdapter(src);\n    let mut iter = iov_iter_source(&mut src);\n    let written = file.write_iter_from(&mut iter, pos)?;\n    if written != 0 {\n        notify_inode_event(file.inode(), IN_MODIFY);\n    }\n    Ok(written)\n}\n\nfn write_file_from_io(",
    "published IN_MODIFY after positioned and sequential writes",
)
patch_file(
    "posix/fs/src/io.rs",
    "    let mut src = IoSourceAdapter(src);\n    let mut iter = iov_iter_source(&mut src);\n    file.write_iter_from(&mut iter, &mut offset)\n}\n\nfn reject_positioned_stream_io(",
    "    let mut src = IoSourceAdapter(src);\n    let mut iter = iov_iter_source(&mut src);\n    let written = file.write_iter_from(&mut iter, &mut offset)?;\n    if written != 0 {\n        notify_inode_event(file.inode(), IN_MODIFY);\n    }\n    Ok(written)\n}\n\nfn reject_positioned_stream_io(",
    "published IN_MODIFY after positioned writes",
)

patch_file(
    "posix/fs/src/fd_ops.rs",
    "use core::ffi::c_int;\n",
    "use alloc::sync::Arc;\nuse core::ffi::c_int;\n\nuse kfd_objects::inotify::{notify_inode_event, IN_CLOSE_WRITE};\n",
    "imported inode close-write notification hook",
)
patch_file(
    "posix/fs/src/fd_ops.rs",
    "pub fn sys_close(fd: c_int) -> KResult<isize> {\n    debug!(\"sys_close <= {fd}\");\n    kprocess::current_resources().close_file(fd)?;\n    Ok(0)\n}\n",
    "pub fn sys_close(fd: c_int) -> KResult<isize> {\n    debug!(\"sys_close <= {fd}\");\n    let resources = kprocess::current_resources();\n    let file = resources.get_file(fd)?;\n    if file.mode().contains(FMode::WRITE) && Arc::strong_count(&file) == 2 {\n        notify_inode_event(file.inode(), IN_CLOSE_WRITE);\n    }\n    resources.close_file(fd)?;\n    Ok(0)\n}\n",
    "published IN_CLOSE_WRITE on final writable descriptor close",
)

patch_file(
    "net/knet/src/netlink/mod.rs",
    "use core::sync::atomic::AtomicU64;\n",
    "use core::sync::atomic::{AtomicBool, AtomicU64};\n",
    "imported AtomicBool for netlink passcred",
)
patch_file(
    "net/knet/src/netlink/mod.rs",
    "    pub(super) protocol: i32,\n    pub(super) local_addr: RwLock<Option<NetlinkAddr>>,\n",
    "    pub(super) protocol: i32,\n    pub(super) pass_credentials: AtomicBool,\n    pub(super) local_addr: RwLock<Option<NetlinkAddr>>,\n",
    "added NETLINK SO_PASSCRED state",
)
patch_file(
    "net/knet/src/netlink/socket.rs",
    "use alloc::{format, sync::Arc, vec, vec::Vec};\n",
    "use alloc::{boxed::Box, format, sync::Arc, vec, vec::Vec};\n",
    "imported Box for NETLINK ancillary credentials",
)
patch_file(
    "net/knet/src/netlink/socket.rs",
    "                protocol,\n                local_addr: ksync::RwLock::new(None),\n",
    "                protocol,\n                pass_credentials: core::sync::atomic::AtomicBool::new(false),\n                local_addr: ksync::RwLock::new(None),\n",
    "initialized NETLINK SO_PASSCRED state",
)
patch_file(
    "net/knet/src/netlink/socket.rs",
    "    options::{Configurable, GetSocketOption, OptionHandled, SetSocketOption},\n",
    "    options::{Configurable, GetSocketOption, OptionHandled, SetSocketOption, UnixCredentials},\n    KernelAncillaryData,\n",
    "imported kernel credential ancillary type",
)
patch_file(
    "net/knet/src/netlink/socket.rs",
    "impl Configurable for NetlinkSocket {\n    fn get_option_inner(&self, opt: &mut GetSocketOption) -> KResult<OptionHandled> {\n        self.inner.general.get_option_inner(opt)\n    }\n\n    fn set_option_inner(&self, opt: SetSocketOption) -> KResult<OptionHandled> {\n        self.inner.general.set_option_inner(opt)\n    }\n}\n",
    "impl Configurable for NetlinkSocket {\n    fn get_option_inner(&self, opt: &mut GetSocketOption) -> KResult<OptionHandled> {\n        match opt {\n            GetSocketOption::PassCredentials(enabled) => {\n                **enabled = self.inner.pass_credentials.load(Ordering::Acquire);\n                Ok(OptionHandled::Yes)\n            }\n            _ => self.inner.general.get_option_inner(opt),\n        }\n    }\n\n    fn set_option_inner(&self, opt: SetSocketOption) -> KResult<OptionHandled> {\n        match opt {\n            SetSocketOption::PassCredentials(enabled) => {\n                self.inner.pass_credentials.store(*enabled, Ordering::Release);\n                Ok(OptionHandled::Yes)\n            }\n            _ => self.inner.general.set_option_inner(opt),\n        }\n    }\n}\n",
    "implemented NETLINK SO_PASSCRED option",
)
patch_file(
    "net/knet/src/netlink/socket.rs",
    "                if let Some(from) = options.from.as_deref_mut() {\n                    *from = SocketAddrEx::Netlink(packet.from);\n                }\n\n                let write_len = packet_len.min(dst.remaining_mut());\n",
    "                if let Some(from) = options.from.as_deref_mut() {\n                    *from = SocketAddrEx::Netlink(packet.from);\n                }\n                if self.inner.pass_credentials.load(Ordering::Acquire)\n                    && let Some(ancillary) = options.ancillary.as_deref_mut()\n                {\n                    ancillary.push(Box::new(KernelAncillaryData::Credentials(\n                        UnixCredentials::new(0),\n                    )));\n                }\n\n                let write_len = packet_len.min(dst.remaining_mut());\n",
    "attached kernel SCM_CREDENTIALS to NETLINK packets",
)

patch_file(
    "net/knet/src/socket/mod.rs",
    "    options::{Configurable, GetSocketOption, OptionHandled, SetSocketOption},\n",
    "    options::{Configurable, GetSocketOption, OptionHandled, SetSocketOption, UnixCredentials},\n",
    "imported UnixCredentials into socket ancillary enum",
)
patch_file(
    "net/knet/src/socket/mod.rs",
    "pub enum KernelAncillaryData {\n    IpError(SocketErrorInfo),\n}\n",
    "pub enum KernelAncillaryData {\n    IpError(SocketErrorInfo),\n    Credentials(UnixCredentials),\n}\n",
    "added kernel credential ancillary data variant",
)
patch_file(
    "posix/net/src/io.rs",
    "        return Some(match *ancillary {\n            KernelAncillaryData::IpError(err) => SocketAncillary::IpError(err),\n        });\n",
    "        return Some(match *ancillary {\n            KernelAncillaryData::IpError(err) => SocketAncillary::IpError(err),\n            KernelAncillaryData::Credentials(cred) => SocketAncillary::Credentials { cred },\n        });\n",
    "marshalled kernel SCM_CREDENTIALS into user cmsgs",
)

print("[done] inotify init/watch/read queue and NETLINK SO_PASSCRED integrations applied")
