#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""G17：让 AF_UNIX 上的 SCM_CREDENTIALS 可用（对齐 Linux 语义）。

背景
----
Chromium 的 crashpad handler 走 AF_UNIX SOCK_SEQPACKET 做 IPC，并用 cmsg 传
对端凭证。x-kernel 的 `CMsg::parse` 只认 SCM_RIGHTS，其余一律
`_ => Err(InvalidInput)`，于是 `sendmsg` 返回 EINVAL(22) —— Linux 对**良构**的
SCM_CREDENTIALS 返回 0。crashpad 因此报 `missing credentials` 并让子进程
在初始化阶段静默退出（rc=191）。见 report/13 / report/16。

对齐的 Linux 语义（net/core/scm.c）
----------------------------------
`scm_send()` 遇到 (SOL_SOCKET, SCM_CREDENTIALS)：
  1. `cmsg_len` 必须**恰好**等于 `CMSG_LEN(sizeof(struct ucred))`，否则 EINVAL；
  2. 取出 pid/uid/gid，交给 `scm_check_creds()`：只有
         (pid == 本进程 tgid 或 CAP_SYS_ADMIN)
      且 (uid 属于自身 uid 集合或 CAP_SYS_ADMIN)
      且 (gid 属于自身 gid 集合或 CAP_SYS_ADMIN)
     才返回 0，否则 **EPERM**。
  3. 通过后，消息携带**声明值**（因此拿到 CAP_SYS_ADMIN 才可代他人声明）。

本补丁实现同样的两条判据（uid/gid 侧只看 euid/egid，不枚举 uid/suid/fsuid，
已在 report/16 记为已知的次要偏差）。

为什么只改两个文件
------------------
`posix/net/src/io.rs` 的 `into_socket_ancillary` 已经会把**发送方**投递过来的
`CMsg` 反序列化回 `msg_control`（P1 建立的 SCM_RIGHTS 通道走的就是它）。
所以只要 `CMsg` 多一个 `Credentials` 变体并在 `push_socket_cmsg` 里补一条
序列化分支，接收端就自动能收到 SCM_CREDENTIALS —— **不需要改 knet**。

用法：python3 p5_scm_credentials.py <x-kernel 仓库根>
幂等：重复执行不会重复插入（命中即返回）。
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else pathlib.Path.cwd()
CMSG = ROOT / "posix/net/src/cmsg.rs"
IO = ROOT / "posix/net/src/io.rs"

applied = 0


def replace_once(path: pathlib.Path, old: str, new: str, label: str) -> None:
    """精确替换一次；已应用则跳过（幂等）。"""
    global applied
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count == 0:
        if new in text:
            print(f"  [skip] {label}（已应用）")
            return
        raise SystemExit(f"!! {label}: 在 {path.name} 中找不到锚点（0 处匹配）")
    if count != 1:
        raise SystemExit(f"!! {label}: 锚点在 {path.name} 中出现 {count} 次，拒绝自动改")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"  [ ok ] {label}")
    applied += 1


print(f"G17 SCM_CREDENTIALS 补丁 -> {ROOT}")

# ============================================================ posix/net/src/cmsg.rs
print("[cmsg.rs] 发送侧解析")

# 1) import：SCM_CREDENTIALS 常量 + ucred 结构
replace_once(
    CMSG,
    "    AF_INET, AF_UNSPEC, IP_RECVERR, IPPROTO_IP, SCM_RIGHTS, SOL_SOCKET, cmsghdr, in_addr,\n"
    "    sockaddr_in,\n",
    "    AF_INET, AF_UNSPEC, IP_RECVERR, IPPROTO_IP, SCM_CREDENTIALS, SCM_RIGHTS, SOL_SOCKET,\n"
    "    cmsghdr, in_addr, sockaddr_in, ucred,\n",
    "import SCM_CREDENTIALS / ucred",
)

# 2) import：UnixCredentials
replace_once(
    CMSG,
    "use knet::{SocketErrorInfo, SocketErrorOrigin};",
    "use knet::{SocketErrorInfo, SocketErrorOrigin, options::UnixCredentials};",
    "import knet::options::UnixCredentials",
)

# 3) CMsg 增加 Credentials 变体
replace_once(
    CMSG,
    "pub(crate) enum CMsg {\n"
    "    /// SCM_RIGHTS: file descriptor passing between processes\n"
    "    Rights { fds: Vec<Arc<VfsFile>> },\n"
    "}\n",
    "pub(crate) enum CMsg {\n"
    "    /// SCM_RIGHTS: file descriptor passing between processes\n"
    "    Rights { fds: Vec<Arc<VfsFile>> },\n"
    "    /// SCM_CREDENTIALS: the sender's credentials, attached to one message\n"
    "    Credentials { cred: UnixCredentials },\n"
    "}\n",
    "CMsg::Credentials 变体",
)

# 4) parse：接受 SCM_CREDENTIALS，按 Linux 的两条判据校验
NEW_ARM = (
    "            (SOL_SOCKET, SCM_CREDENTIALS) => {\n"
    "                // Linux requires the payload to be exactly one `struct ucred`\n"
    "                // (`scm_send`): any other length is EINVAL.\n"
    "                if data.len() != size_of::<ucred>() {\n"
    "                    return Err(KError::InvalidInput);\n"
    "                }\n"
    "                let claimed = ucred {\n"
    "                    pid: u32::from_ne_bytes(data[0..4].try_into().unwrap()),\n"
    "                    uid: u32::from_ne_bytes(data[4..8].try_into().unwrap()),\n"
    "                    gid: u32::from_ne_bytes(data[8..12].try_into().unwrap()),\n"
    "                };\n"
    "                // `scm_check_creds`: a sender may only claim its own identity.\n"
    "                // Anything else needs CAP_SYS_ADMIN, otherwise EPERM.\n"
    "                let cred = kprocess::current_cred();\n"
    "                let privileged = cred.is_privileged();\n"
    "                let pid_ok = privileged || claimed.pid == kprocess::current_user_thread().pid();\n"
    "                let uid_ok = privileged || claimed.uid == cred.euid();\n"
    "                let gid_ok = privileged || claimed.gid == cred.egid();\n"
    "                if !(pid_ok && uid_ok && gid_ok) {\n"
    "                    return Err(KError::from(LinuxError::EPERM));\n"
    "                }\n"
    "                Self::Credentials {\n"
    "                    cred: UnixCredentials {\n"
    "                        pid: claimed.pid,\n"
    "                        uid: claimed.uid,\n"
    "                        gid: claimed.gid,\n"
    "                    },\n"
    "                }\n"
    "            }\n"
)
replace_once(
    CMSG,
    "                Self::Rights { fds }\n"
    "            }\n"
    "            _ => {\n"
    "                return Err(KError::InvalidInput);\n"
    "            }\n",
    "                Self::Rights { fds }\n"
    "            }\n"
    + NEW_ARM
    + "            _ => {\n"
    "                return Err(KError::InvalidInput);\n"
    "            }\n",
    "parse 分支 SCM_CREDENTIALS",
)

# ============================================================ posix/net/src/io.rs
print("[io.rs] 接收侧序列化")

# 5) import：UnixCredentials
replace_once(
    IO,
    "    AncillaryData, KernelAncillaryData, RecvFlags, RecvOptions, SendFlags, SendOptions, Socket,\n",
    "    AncillaryData, KernelAncillaryData, RecvFlags, RecvOptions, SendFlags, SendOptions, Socket,\n"
    "    options::UnixCredentials,\n",
    "import knet::options::UnixCredentials",
)

# 6) import：SCM_CREDENTIALS 常量 + ucred 结构
replace_once(
    IO,
    "        MSG_CTRUNC, MSG_DONTWAIT, MSG_ERRQUEUE, MSG_PEEK, MSG_TRUNC, SCM_RIGHTS, SOL_SOCKET,\n"
    "        cmsghdr, mmsghdr, msghdr, sockaddr, socklen_t,\n",
    "        MSG_CTRUNC, MSG_DONTWAIT, MSG_ERRQUEUE, MSG_PEEK, MSG_TRUNC, SCM_CREDENTIALS, SCM_RIGHTS,\n"
    "        SOL_SOCKET, cmsghdr, mmsghdr, msghdr, sockaddr, socklen_t, ucred,\n",
    "import SCM_CREDENTIALS / ucred",
)

# 7) SocketAncillary 增加 Credentials 变体
replace_once(
    IO,
    "enum SocketAncillary {\n"
    "    Rights { fds: Vec<Arc<VfsFile>> },\n"
    "    IpError(SocketErrorInfo),\n"
    "}\n",
    "enum SocketAncillary {\n"
    "    Rights { fds: Vec<Arc<VfsFile>> },\n"
    "    Credentials { cred: UnixCredentials },\n"
    "    IpError(SocketErrorInfo),\n"
    "}\n",
    "SocketAncillary::Credentials 变体",
)

# 8) 发送方 CMsg -> 接收侧 SocketAncillary
replace_once(
    IO,
    "            CMsg::Rights { fds } => SocketAncillary::Rights { fds },\n",
    "            CMsg::Rights { fds } => SocketAncillary::Rights { fds },\n"
    "            CMsg::Credentials { cred } => SocketAncillary::Credentials { cred },\n",
    "into_socket_ancillary 分支",
)

# 9) 序列化为 SCM_CREDENTIALS cmsg
replace_once(
    IO,
    "        SocketAncillary::IpError(err) => push_ip_recverr_cmsg(builder, err),\n    }\n",
    "        SocketAncillary::Credentials { cred } => {\n"
    "            builder.push(SOL_SOCKET, SCM_CREDENTIALS, |data| {\n"
    "                if data.len() < size_of::<ucred>() {\n"
    "                    return Err(KError::from(LinuxError::ENOBUFS));\n"
    "                }\n"
    "                // 小端/大端一律按本机序；逐字段写字节以避免对齐假设。\n"
    "                data[0..4].copy_from_slice(&cred.pid.to_ne_bytes());\n"
    "                data[4..8].copy_from_slice(&cred.uid.to_ne_bytes());\n"
    "                data[8..12].copy_from_slice(&cred.gid.to_ne_bytes());\n"
    "                Ok(size_of::<ucred>())\n"
    "            })\n"
    "        }\n"
    "        SocketAncillary::IpError(err) => push_ip_recverr_cmsg(builder, err),\n"
    "    }\n",
    "push_socket_cmsg 分支",
)

print(f"\n[done] G17 SCM_CREDENTIALS 补丁：本次实际改动 {applied} 处"
      f"（幂等，其余为已应用跳过）")
