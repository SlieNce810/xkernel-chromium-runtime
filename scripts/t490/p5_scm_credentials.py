#!/usr/bin/env python3
"""Apply the narrow G17 SCM_CREDENTIALS compatibility patch on T490."""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else pathlib.Path.cwd()
CMSG = ROOT / "posix/net/src/cmsg.rs"
IO = ROOT / "posix/net/src/io.rs"


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count == 0 and new in text:
        return
    if count != 1:
        raise SystemExit(f"expected one match in {path}, found {count}")
    path.write_text(text.replace(old, new))


replace_once(
    CMSG,
    "use knet::{SocketErrorInfo, SocketErrorOrigin};",
    "use knet::{SocketErrorInfo, SocketErrorOrigin, options::UnixCredentials};",
)
replace_once(
    IO,
    "        MSG_CTRUNC, MSG_DONTWAIT, MSG_ERRQUEUE, MSG_PEEK, MSG_TRUNC, SCM_RIGHTS, SOL_SOCKET,",
    "        MSG_CTRUNC, MSG_DONTWAIT, MSG_ERRQUEUE, MSG_PEEK, MSG_TRUNC, SCM_CREDENTIALS, SCM_RIGHTS, SOL_SOCKET,",
)
replace_once(
    IO,
    "    cmsg::{CMsg, CMsgBuilder, push_ip_recverr_cmsg},",
    "    cmsg::{CMsg, CMsgBuilder, push_ip_recverr_cmsg},\n    options::UnixCredentials,",
)
replace_once(
    IO,
    "    Rights { fds: Vec<Arc<VfsFile>> },\n    IpError(SocketErrorInfo),",
    "    Rights { fds: Vec<Arc<VfsFile>> },\n    Credentials { cred: UnixCredentials },\n    IpError(SocketErrorInfo),",
)
replace_once(
    CMSG,
    "            (SOL_SOCKET, SCM_RIGHTS) => {\n                if data.len() % size_of::<i32>() != 0 {",
    "            (SOL_SOCKET, SCM_CREDENTIALS) => {\n                if data.len() < 12 || !kprocess::current_cred().is_privileged() {\n                    return Err(KError::from(LinuxError::EPERM));\n                }\n                Self::Credentials {\n                    cred: UnixCredentials {\n                        pid: kprocess::current_user_thread().pid(),\n                        uid: kprocess::current_cred().euid(),\n                        gid: kprocess::current_cred().egid(),\n                    },\n                }\n            }\n            (SOL_SOCKET, SCM_RIGHTS) => {\n                if data.len() % size_of::<i32>() != 0 {",
)
replace_once(
    CMSG,
    "AF_INET, AF_UNSPEC, IP_RECVERR, IPPROTO_IP, SCM_RIGHTS, SOL_SOCKET, cmsghdr, in_addr,",
    "AF_INET, AF_UNSPEC, IP_RECVERR, IPPROTO_IP, SCM_CREDENTIALS, SCM_RIGHTS, SOL_SOCKET, cmsghdr, in_addr,",
)
replace_once(
    CMSG,
    "    Rights { fds: Vec<Arc<VfsFile>> },\n}",
    "    Rights { fds: Vec<Arc<VfsFile>> },\n    Credentials { cred: UnixCredentials },\n}",
)
replace_once(
    IO,
    "            CMsg::Rights { fds } => SocketAncillary::Rights { fds },\n        });",
    "            CMsg::Rights { fds } => SocketAncillary::Rights { fds },\n            CMsg::Credentials { cred } => SocketAncillary::Credentials { cred },\n        });",
)
replace_once(
    IO,
    "        SocketAncillary::IpError(err) => push_ip_recverr_cmsg(builder, err),\n    }",
    "        SocketAncillary::Credentials { cred } => builder.push(SOL_SOCKET, SCM_CREDENTIALS, |data| {\n            if data.len() < 12 {\n                return Err(KError::from(LinuxError::ENOBUFS));\n            }\n            data[0..4].copy_from_slice(&(cred.pid as i32).to_ne_bytes());\n            data[4..8].copy_from_slice(&cred.uid.to_ne_bytes());\n            data[8..12].copy_from_slice(&cred.gid.to_ne_bytes());\n            Ok(12)\n        }),\n        SocketAncillary::IpError(err) => push_ip_recverr_cmsg(builder, err),\n    }",
)
print("[done] G17 SCM_CREDENTIALS patch applied")
