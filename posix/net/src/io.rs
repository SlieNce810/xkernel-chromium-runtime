// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Network I/O syscalls.
//!
//! This module implements network I/O operations including:
//! - Send and receive (send, recv, sendto, recvfrom, etc.)
//! - Vectored I/O (sendmsg, recvmsg, etc.)
//! - Out-of-band data handling
//! - Ancillary data (control messages)

use alloc::{boxed::Box, sync::Arc, vec::Vec};
use core::{any::TypeId, net::Ipv4Addr, sync::atomic::{AtomicUsize, Ordering}};

use kerrno::{KError, KErrorKind, KResult, LinuxError};
use khal::time::monotonic_time;
use kio::prelude::*;
use knet::{
    AncillaryData, KernelAncillaryData, RecvFlags, RecvOptions, SendFlags, SendOptions, Socket,
    SocketAddrEx, SocketErrorInfo, SocketOps,
    options::{Configurable, GetSocketOption, UnixCredentials}, sock_from_file,
};
use ktime_types::{MonotonicInstant, TimeSpan};
use kvfs::VfsFile;
use linux_raw_sys::{
    general::timespec,
    net::{
        MSG_CMSG_CLOEXEC, MSG_CTRUNC, MSG_DONTWAIT, MSG_ERRQUEUE, MSG_PEEK, MSG_TRUNC,
        SCM_CREDENTIALS, SCM_RIGHTS, SOL_SOCKET, cmsghdr, mmsghdr, msghdr, sockaddr, socklen_t,
        ucred,
    },
};
use osvm::{VirtPtr, VmBytes, VmBytesMut, write_vm_mem};
use posix_types::{IoVec, IoVectorBuf, TimeSpanLike, UserConstPtr, UserPtr};

use crate::{
    addr::SocketAddrExt,
    cmsg::{CMsg, CMsgBuilder, cmsg_space_len, push_ip_recverr_cmsg},
};

// Temporary, bounded Chromium AF_UNIX syscall trace for the renderer channel audit.
static CHROMIUM_UNIX_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);
const CHROMIUM_UNIX_TRACE_LIMIT: usize = 4096;
static CHROMIUM_SCM_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);
const CHROMIUM_SCM_TRACE_LIMIT: usize = 2048;
static CHROMIUM_BYTES_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);
const CHROMIUM_BYTES_TRACE_LIMIT: usize = 2048;
fn trace_chromium_unix_call(op: &str, fd: i32, flags: u32, file: &VfsFile, ancillary_count: usize) -> Option<usize> {
    // Earlier startup traffic consumes the trace budget before navigation.
    // Start just before the measured FileURLLoader window (guest uptime ~125s).
    if monotonic_time() < MonotonicInstant::from_span_since_origin(TimeSpan::from_secs(70)) {
        return None;
    }
    if fd < 3 {
        return None;
    }
    let process = kprocess::current_user_process();
    let argv = process.cmdline().ok()?;
    let is_chromium = argv.iter().any(|arg| arg.contains("/chromium"));
    if !is_chromium {
        return None;
    }
    let role = if argv.iter().any(|arg| arg == "--type=zygote") {
        "zygote"
    } else if argv.iter().any(|arg| arg == "--type=renderer") {
        "renderer"
    } else if argv.iter().any(|arg| arg == "--type=utility") {
        "utility"
    } else {
        "browser"
    };
    let sequence = CHROMIUM_UNIX_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    if sequence >= CHROMIUM_UNIX_TRACE_LIMIT {
        return None;
    }
    let pid = process.pid();
    let task_name = kprocess::current_user_thread().task_name();
    warn!("CHROMIUM_UNIX_IPC seq={} op={} role={} task_name={:?} pid={} fd={} flags={:#x} ancillary={} target={:?}",
        sequence, op, role, task_name, pid, fd, flags, ancillary_count, file.path().absolute_path());
    Some(sequence)
}

fn trace_chromium_msg_bytes(op: &str, fd: i32, iov_ptr: usize, iov_len: usize) {
    if fd < 4 || fd > 200
        || monotonic_time() < MonotonicInstant::from_span_since_origin(TimeSpan::from_secs(70))
    {
        return;
    }
    let process = kprocess::current_user_process();
    let argv = match process.cmdline() {
        Ok(argv) => argv,
        Err(_) => return,
    };
    if !argv.iter().any(|arg| arg.contains("/chromium")) {
        return;
    }
    let role = if argv.iter().any(|arg| arg == "--type=zygote") {
        "zygote"
    } else if argv.iter().any(|arg| arg == "--type=renderer") {
        "renderer"
    } else {
        "browser"
    };
    let Ok(iovs) = IoVec::load_from_user(UserConstPtr::from(iov_ptr), iov_len) else {
        return;
    };
    let Some(iov) = iovs.first() else { return };
    if iov.iov_len <= 0 { return; }
    let sample_len = (iov.iov_len as usize).min(4096);
    let Ok(bytes) = UserConstPtr::<u8>::from(iov.iov_base as usize).load_vm_vec(sample_len) else {
        return;
    };
    if bytes.len() >= 32 && bytes[0..4] == [16, 0, 0, 0] {
        let payload_len = u32::from_ne_bytes(bytes[4..8].try_into().unwrap());
        let route_or_id = u32::from_ne_bytes(bytes[20..24].try_into().unwrap());
        if bytes.len() >= 64
            && u16::from_ne_bytes(bytes[16..18].try_into().unwrap()) == 24
            && u16::from_ne_bytes(bytes[18..20].try_into().unwrap()) == 20
        {
            // The outer channel frame has a 16-byte header. The ipcz
            // MessageHeader starts at byte 16, followed by the generated
            // AcceptParcel struct at the offsets below.
            let sublink = u64::from_ne_bytes(bytes[48..56].try_into().unwrap());
            let sequence = u64::from_ne_bytes(bytes[56..64].try_into().unwrap());
            let subparcel = u32::from_ne_bytes(bytes[64..68].try_into().unwrap());
            let num_subparcels = u32::from_ne_bytes(bytes[68..72].try_into().unwrap());
            let buffer_id = u64::from_ne_bytes(bytes[72..80].try_into().unwrap());
            let offset = u32::from_ne_bytes(bytes[80..84].try_into().unwrap());
            let size = u32::from_ne_bytes(bytes[84..88].try_into().unwrap());
            warn!("CHROMIUM_IPCZ_ACCEPT op={} role={} pid={} fd={} sublink={} sequence={} subparcel={} num_subparcels={} buffer_id={} offset={} size={}",
                op, role, process.pid(), fd, sublink, sequence, subparcel,
                num_subparcels, buffer_id, offset, size);
        }
        let mut candidates = [0u32; 8];
        let mut count = 0usize;
        for chunk in bytes.chunks_exact(4) {
            let value = u32::from_ne_bytes(chunk.try_into().unwrap());
            if (94208..=131072).contains(&value) && count < candidates.len() {
                candidates[count] = value;
                count += 1;
            }
        }
        warn!("CHROMIUM_IPCZ_FRAME op={} role={} pid={} fd={} wire_len={} payload_len={} route_or_id={} frag_candidates={:?}",
            op, role, process.pid(), fd, iov_len, payload_len, route_or_id, &candidates[..count]);
    }
    let seq = CHROMIUM_BYTES_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    if seq < CHROMIUM_BYTES_TRACE_LIMIT {
        warn!("CHROMIUM_UNIX_BYTES seq={} op={} role={} pid={} fd={} len={} bytes={:?}",
            seq, op, role, process.pid(), fd, iov.iov_len, bytes);
    }
}

// Linux ABI for sendmmsg/recvmmsg limits vlen to UIO_MAXIOV (1024).
const MMSG_MAX_VLEN: u32 = 1024;

fn parse_send_flags(flags: u32) -> SendFlags {
    let mut send_flags = SendFlags::empty();
    if flags & MSG_DONTWAIT != 0 {
        send_flags |= SendFlags::DONT_WAIT;
    }
    send_flags
}

fn parse_recvmmsg_timeout(timeout: UserConstPtr<timespec>) -> KResult<Option<TimeSpan>> {
    if timeout.is_null() {
        return Ok(None);
    }
    Ok(Some(timeout.read_vm()?.try_into_time_span()?))
}

fn parse_send_cmsgs(
    resources: &kresources::ProcessResources,
    control_ptr: usize,
    control_len: usize,
) -> KResult<Vec<AncillaryData>> {
    let mut ancillary = Vec::new();
    if control_ptr == 0 || control_len == 0 {
        return Ok(ancillary);
    }

    let mut ptr = control_ptr;
    let ptr_end = ptr.checked_add(control_len).ok_or(KError::InvalidInput)?;

    while let Some(next) = ptr.checked_add(size_of::<cmsghdr>()) {
        if next > ptr_end {
            break;
        }

        let hdr_ptr = UserConstPtr::<cmsghdr>::from(ptr);
        let hdr = hdr_ptr.read_vm()?;
        let cmsg_len = hdr.cmsg_len as usize;
        if cmsg_len < size_of::<cmsghdr>() || ptr_end - ptr < cmsg_len {
            return Err(KError::InvalidInput);
        }

        ancillary.push(Box::new(CMsg::parse(resources, hdr_ptr, hdr)?) as AncillaryData);
        // The final cmsg may omit trailing padding, but a following header
        // must begin at CMSG_ALIGN just like Linux's CMSG_NXTHDR.
        let aligned_len = cmsg_space_len(cmsg_len)?;
        ptr += if aligned_len <= ptr_end - ptr {
            aligned_len
        } else {
            cmsg_len
        };
    }

    Ok(ancillary)
}

enum SocketAncillary {
    Rights { fds: Vec<Arc<VfsFile>> },
    Credentials { cred: UnixCredentials },
    IpError(SocketErrorInfo),
}

fn into_socket_ancillary(ancillary: AncillaryData) -> Option<SocketAncillary> {
    // `AncillaryData` is the type-erased boundary between `posix-net` and `knet`.
    // Send-side cmsgs carry `posix-net`-owned `CMsg`, while receive-side
    // asynchronous errors are produced by `knet` as `KernelAncillaryData`.
    let type_id = ancillary.as_ref().type_id();
    if type_id == TypeId::of::<CMsg>() {
        let ancillary = ancillary.downcast::<CMsg>().ok()?;
        return Some(match *ancillary {
            CMsg::Rights { fds } => SocketAncillary::Rights { fds },
            CMsg::Credentials { cred } => SocketAncillary::Credentials { cred },
        });
    }
    if type_id == TypeId::of::<KernelAncillaryData>() {
        let ancillary = ancillary.downcast::<KernelAncillaryData>().ok()?;
        return Some(match *ancillary {
            KernelAncillaryData::IpError(err) => SocketAncillary::IpError(err),
            KernelAncillaryData::Credentials(cred) => SocketAncillary::Credentials { cred },
        });
    }

    None
}

fn push_socket_cmsg(
    resources: &kresources::ProcessResources,
    builder: &mut CMsgBuilder<'_>,
    ancillary: SocketAncillary,
    close_on_exec: bool,
) -> KResult<bool> {
    match ancillary {
        SocketAncillary::Rights { fds } => builder.push(SOL_SOCKET, SCM_RIGHTS, |data| {
            let body_len = fds
                .len()
                .checked_mul(size_of::<i32>())
                .ok_or(KError::from(LinuxError::ENOBUFS))?;
            if data.len() < body_len {
                return Err(KError::from(LinuxError::ENOBUFS));
            }

            let mut written = 0;
            for (f, chunk) in fds
                .into_iter()
                .zip(data[..body_len].chunks_exact_mut(size_of::<i32>()))
            {
                let target = f.path().absolute_path();
                let fd = resources.add_file(f, close_on_exec)?;
                let trace_seq = CHROMIUM_SCM_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
                if trace_seq < CHROMIUM_SCM_TRACE_LIMIT
                    && monotonic_time() >= MonotonicInstant::from_span_since_origin(TimeSpan::from_secs(70))
                {
                    warn!("CHROMIUM_SCM_RIGHTS seq={} pid={} new_fd={} close_on_exec={} target={:?}",
                        trace_seq, kprocess::current_user_process().pid(), fd, close_on_exec, target);
                }
                chunk.copy_from_slice(&fd.to_ne_bytes());
                written += size_of::<i32>();
            }
            Ok(written)
        }),
        SocketAncillary::Credentials { cred } => {
            builder.push(SOL_SOCKET, SCM_CREDENTIALS, |data| {
                if data.len() < size_of::<ucred>() {
                    return Err(KError::from(LinuxError::ENOBUFS));
                }
                // 小端/大端一律按本机序；逐字段写字节以避免对齐假设。
                data[0..4].copy_from_slice(&cred.pid.to_ne_bytes());
                data[4..8].copy_from_slice(&cred.uid.to_ne_bytes());
                data[8..12].copy_from_slice(&cred.gid.to_ne_bytes());
                Ok(size_of::<ucred>())
            })
        }
        SocketAncillary::IpError(err) => push_ip_recverr_cmsg(builder, err),
    }
}

/// Send data on a socket with optional destination address and ancillary data
fn send_impl(
    fd: i32,
    mut src: impl Read + IoBuf,
    flags: u32,
    addr: UserConstPtr<sockaddr>,
    addrlen: socklen_t,
    ancillary: Vec<AncillaryData>,
) -> KResult<isize> {
    let addr = if addr.is_null() || addrlen == 0 {
        None
    } else {
        Some(SocketAddrEx::read_from_user(addr, addrlen)?)
    };

    debug!("sys_send <= fd: {fd}, flags: {flags}, addr: {addr:?}");

    let file = kprocess::current_resources().get_file(fd)?;
    let socket = sock_from_file(&file)?;
    let mut send_flags = parse_send_flags(flags);
    if file.is_nonblocking() {
        send_flags |= SendFlags::DONT_WAIT;
    }
    let ancillary_count = ancillary.len();
    let trace_seq = matches!(socket.as_ref(), Socket::Unix(_))
        .then(|| trace_chromium_unix_call("send", fd, flags, file.as_ref(), ancillary_count))
        .flatten();
    let options = SendOptions {
        to: addr,
        flags: send_flags,
        ancillary,
    };
    let sent_result = match socket.as_ref() {
        Socket::Netlink(_) => {
            let cred = kprocess::current_cred();
            socket.send_with_cred(&mut src, options, &cred)
        }
        _ => socket.send(&mut src, options),
    };
    if let Some(sequence) = trace_seq {
        match &sent_result {
            Ok(sent) => warn!("CHROMIUM_UNIX_IPC seq={} op=send-result fd={} bytes={}", sequence, fd, sent),
            Err(error) => warn!("CHROMIUM_UNIX_IPC seq={} op=send-error fd={} err={:?}", sequence, fd, error),
        }
    }
    let sent = sent_result?;
    Ok(sent as isize)
}

/// Send data to a specific address on a socket
pub fn sys_sendto(
    fd: i32,
    buf: *const u8,
    len: usize,
    flags: u32,
    addr: UserConstPtr<sockaddr>,
    addrlen: socklen_t,
) -> KResult<isize> {
    send_impl(fd, VmBytes::new(buf, len), flags, addr, addrlen, Vec::new())
}

/// Send data with vectored I/O and ancillary data (control messages)
pub fn sys_sendmsg(fd: i32, msg: UserConstPtr<msghdr>, flags: u32) -> KResult<isize> {
    let msg = msg.read_vm()?;
    trace_chromium_msg_bytes("send", fd, msg.msg_iov as usize, msg.msg_iovlen);
    let resources = kprocess::current_resources();
    let ancillary = parse_send_cmsgs(
        resources.as_ref(),
        msg.msg_control as usize,
        msg.msg_controllen,
    )?;
    send_impl(
        fd,
        IoVectorBuf::from_iovecs(IoVec::load_from_user(
            posix_types::UserConstPtr::from(msg.msg_iov as usize),
            msg.msg_iovlen,
        )?)?
        .into_io(),
        flags,
        UserConstPtr::from(msg.msg_name as usize),
        msg.msg_namelen as socklen_t,
        ancillary,
    )
}

/// Receive data from a socket with optional remote address and ancillary data collection
struct RecvOutput<'a> {
    addr: UserPtr<sockaddr>,
    addrlen: RecvAddrLen<'a>,
    out_flags: Option<&'a mut RecvFlags>,
    cmsg_builder: Option<CMsgBuilder<'a>>,
    msg_flags: Option<&'a mut u32>,
}

enum RecvAddrLen<'a> {
    User(UserPtr<socklen_t>),
    Value(&'a mut socklen_t),
}

impl RecvAddrLen<'_> {
    fn read(&self) -> KResult<socklen_t> {
        match self {
            RecvAddrLen::User(ptr) => ptr.read_vm().map_err(Into::into),
            RecvAddrLen::Value(value) => Ok(**value),
        }
    }

    fn write(&mut self, value: socklen_t) -> KResult<()> {
        match self {
            RecvAddrLen::User(ptr) => ptr.write_vm(value).map_err(Into::into),
            RecvAddrLen::Value(dst) => {
                **dst = value;
                Ok(())
            }
        }
    }
}

impl<'a> RecvOutput<'a> {
    fn new(addr: UserPtr<sockaddr>, addrlen: UserPtr<socklen_t>) -> Self {
        Self {
            addr,
            addrlen: RecvAddrLen::User(addrlen),
            out_flags: None,
            cmsg_builder: None,
            msg_flags: None,
        }
    }
}

fn recv_impl(
    fd: i32,
    mut dst: impl Write + IoBufMut,
    flags: u32,
    mut output: RecvOutput<'_>,
) -> KResult<isize> {
    debug!("sys_recv <= fd: {fd}, flags: {flags}");

    let resources = kprocess::current_user_process().resources()?;
    let file = resources.get_file(fd)?;
    let socket = sock_from_file(&file)?;
    let cmsg_cloexec = flags & MSG_CMSG_CLOEXEC != 0;
    let mut recv_flags = RecvFlags::empty();
    if flags & MSG_PEEK != 0 {
        recv_flags |= RecvFlags::PEEK;
    }
    if flags & MSG_TRUNC != 0 {
        recv_flags |= RecvFlags::TRUNCATE;
    }
    if flags & MSG_ERRQUEUE != 0 {
        recv_flags |= RecvFlags::ERROR_QUEUE;
    }
    if file.is_nonblocking() || flags & MSG_DONTWAIT != 0 {
        recv_flags |= RecvFlags::DONT_WAIT;
    }

    let mut ancillary = Vec::new();
    let mut reported_flags = RecvFlags::empty();

    let mut remote_addr =
        (!output.addr.is_null()).then(|| SocketAddrEx::Ip((Ipv4Addr::UNSPECIFIED, 0).into()));
    let trace_seq = matches!(socket.as_ref(), Socket::Unix(_))
        .then(|| trace_chromium_unix_call("recv", fd, flags, file.as_ref(), 0))
        .flatten();
    let recv_result = socket.recv(
        &mut dst,
        RecvOptions {
            from: remote_addr.as_mut(),
            flags: recv_flags,
            ancillary: Some(&mut ancillary),
            out_flags: Some(&mut reported_flags),
        },
    );
    if let Some(sequence) = trace_seq {
        match &recv_result {
            Ok(received) => warn!("CHROMIUM_UNIX_IPC seq={} op=recv-result fd={} bytes={} ancillary={}", sequence, fd, received, ancillary.len()),
            Err(error) => {
                let mut peer = UnixCredentials::default();
                match socket.get_option(GetSocketOption::PeerCredentials(&mut peer)) {
                    Ok(()) => warn!("CHROMIUM_UNIX_IPC seq={} op=recv-error fd={} peer_pid={} peer_uid={} peer_gid={} err={:?}",
                        sequence, fd, peer.pid, peer.uid, peer.gid, error),
                    Err(peer_error) => warn!("CHROMIUM_UNIX_IPC seq={} op=recv-error fd={} peer_lookup_error={:?} err={:?}",
                        sequence, fd, peer_error, error),
                }
            }
        }
    }
    let recv = recv_result?;
    if let Some(out_flags) = output.out_flags {
        *out_flags = reported_flags;
    }

    if let Some(remote_addr) = remote_addr {
        let mut addrlen_value = output.addrlen.read()?;
        remote_addr.write_to_user(output.addr, &mut addrlen_value)?;
        output.addrlen.write(addrlen_value)?;
    }

    let mut cmsg_truncated = false;
    if let Some(mut builder) = output.cmsg_builder {
        for ancillary in ancillary {
            let Some(ancillary) = into_socket_ancillary(ancillary) else {
                warn!("received unexpected ancillary");
                continue;
            };
            let push_result =
                push_socket_cmsg(resources.as_ref(), &mut builder, ancillary, cmsg_cloexec);

            match push_result {
                Ok(true) => {}
                Ok(false) => {
                    cmsg_truncated = true;
                    break;
                }
                Err(e) if e == KError::from(LinuxError::ENOBUFS) => {
                    cmsg_truncated = true;
                    break;
                }
                Err(e) => return Err(e),
            }
        }
    }

    if let Some(msg_flags) = output.msg_flags {
        *msg_flags |= recv_truncate_to_msg_flag(reported_flags);
        if flags & MSG_ERRQUEUE != 0 {
            *msg_flags |= MSG_ERRQUEUE;
        }
        if cmsg_truncated {
            *msg_flags |= MSG_CTRUNC;
        }
    }

    debug!("sys_recv => fd: {fd}, recv: {recv}");
    Ok(recv as isize)
}

/// Receive data from a socket with the sender's address
pub fn sys_recvfrom(
    fd: i32,
    buf: *mut u8,
    len: usize,
    flags: u32,
    addr: UserPtr<sockaddr>,
    addrlen: UserPtr<socklen_t>,
) -> KResult<isize> {
    recv_impl(
        fd,
        VmBytesMut::new(buf, len),
        flags,
        RecvOutput::new(addr, addrlen),
    )
}

/// Receive data with vectored I/O and ancillary data (control messages)
pub fn sys_recvmsg(fd: i32, msg: UserPtr<msghdr>, flags: u32) -> KResult<isize> {
    // Chromium's zygote handshake waits in recvmsg while SIGCHLD can arrive
    // for the namespace bootstrap helper. Linux restarts this blocking receive
    // when the installed signal action is restartable; retry a bounded number
    // of EINTR returns here so a transient child signal cannot turn the
    // handshake into a fatal PCHECK.
    for _attempt in 0..16 {
        let mut msg_value = msg.read_vm()?;
        msg_value.msg_flags = 0;
        let mut msg_namelen = msg_value.msg_namelen as socklen_t;
        let result = recv_impl(
            fd,
            IoVectorBuf::from_iovecs(IoVec::load_from_user(
                posix_types::UserConstPtr::from(msg_value.msg_iov as usize),
                msg_value.msg_iovlen,
            )?)?
            .into_io(),
            flags,
            RecvOutput {
                addr: UserPtr::from(msg_value.msg_name as usize),
                addrlen: RecvAddrLen::Value(&mut msg_namelen),
                cmsg_builder: (!msg_value.msg_control.is_null()).then(|| {
                    CMsgBuilder::new(
                        UserPtr::from(msg_value.msg_control as *mut cmsghdr),
                        &mut msg_value.msg_controllen,
                    )
                }),
                msg_flags: Some(&mut msg_value.msg_flags),
                out_flags: None,
            },
        );
        if result.is_ok() {
            trace_chromium_msg_bytes("recv", fd, msg_value.msg_iov as usize, msg_value.msg_iovlen);
        }
        if let Err(error) = result {
            if matches!(KErrorKind::try_from(error), Ok(KErrorKind::Interrupted)) {
                continue;
            }
            msg_value.msg_namelen = msg_namelen as _;
            write_vm_mem(msg.as_ptr().cast_mut(), core::slice::from_ref(&msg_value))?;
            return Err(error);
        }
        msg_value.msg_namelen = msg_namelen as _;
        write_vm_mem(msg.as_ptr().cast_mut(), core::slice::from_ref(&msg_value))?;
        return result;
    }
    Err(KError::from(LinuxError::EINTR))
}

fn recv_truncate_to_msg_flag(flags: RecvFlags) -> u32 {
    if flags.contains(RecvFlags::TRUNCATE) {
        MSG_TRUNC
    } else {
        0
    }
}

/// Send multiple datagrams in one syscall.
pub fn sys_sendmmsg(fd: i32, msgvec: UserPtr<mmsghdr>, vlen: u32, flags: u32) -> KResult<isize> {
    if vlen == 0 {
        return Ok(0);
    }
    if vlen > MMSG_MAX_VLEN {
        return Err(KError::InvalidInput);
    }

    let mut msgvec_value = msgvec.load_vm_vec(vlen as usize)?;
    let resources = kprocess::current_resources();
    let mut sent = 0;
    for msg in msgvec_value.iter_mut() {
        let ancillary = parse_send_cmsgs(
            resources.as_ref(),
            msg.msg_hdr.msg_control as usize,
            msg.msg_hdr.msg_controllen,
        )?;
        match send_impl(
            fd,
            IoVectorBuf::from_iovecs(IoVec::load_from_user(
                posix_types::UserConstPtr::from(msg.msg_hdr.msg_iov as usize),
                msg.msg_hdr.msg_iovlen,
            )?)?
            .into_io(),
            flags,
            UserConstPtr::from(msg.msg_hdr.msg_name as usize),
            msg.msg_hdr.msg_namelen as socklen_t,
            ancillary,
        ) {
            Ok(n) => {
                msg.msg_len = n as u32;
                sent += 1;
            }
            Err(e) => {
                if sent > 0 {
                    write_vm_mem(msgvec.as_ptr().cast_mut(), &msgvec_value)?;
                }
                if sent == 0 {
                    return Err(e);
                }
                break;
            }
        }
    }
    if sent > 0 {
        write_vm_mem(msgvec.as_ptr().cast_mut(), &msgvec_value)?;
    }
    Ok(sent)
}

/// Receive multiple datagrams in one syscall.
pub fn sys_recvmmsg(
    fd: i32,
    msgvec: UserPtr<mmsghdr>,
    vlen: u32,
    flags: u32,
    timeout: UserConstPtr<timespec>,
) -> KResult<isize> {
    if vlen == 0 {
        return Ok(0);
    }
    if vlen > MMSG_MAX_VLEN {
        return Err(KError::InvalidInput);
    }

    let timeout = parse_recvmmsg_timeout(timeout)?;
    // TODO: deadline is only checked between recv_impl calls. If a single
    // recv_impl blocks waiting for data (socket has nothing to read), the
    // deadline cannot interrupt it. Needs a non-blocking recv path or
    // SO_RCVTIMEO support at the socket layer to fix.
    let deadline = timeout.and_then(|span| monotonic_time().checked_add(span));

    let mut msgvec_value = msgvec.load_vm_vec(vlen as usize)?;
    let mut received = 0;
    for msg in msgvec_value.iter_mut() {
        if let Some(deadline) = deadline
            && monotonic_time() >= deadline
        {
            if received == 0 {
                return Err(KError::WouldBlock);
            }
            break;
        }
        msg.msg_hdr.msg_flags = 0;
        match recv_impl(
            fd,
            IoVectorBuf::from_iovecs(IoVec::load_from_user(
                posix_types::UserConstPtr::from(msg.msg_hdr.msg_iov as usize),
                msg.msg_hdr.msg_iovlen,
            )?)?
            .into_io(),
            flags,
            RecvOutput {
                cmsg_builder: (!msg.msg_hdr.msg_control.is_null()).then(|| {
                    CMsgBuilder::new(
                        UserPtr::from(msg.msg_hdr.msg_control as *mut cmsghdr),
                        &mut msg.msg_hdr.msg_controllen,
                    )
                }),
                msg_flags: Some(&mut msg.msg_hdr.msg_flags),
                ..RecvOutput::new(
                    UserPtr::from(msg.msg_hdr.msg_name as usize),
                    UserPtr::from(&mut msg.msg_hdr.msg_namelen as *mut _ as *mut socklen_t),
                )
            },
        ) {
            Ok(n) => {
                msg.msg_len = n as u32;
                received += 1;
            }
            Err(e) => {
                write_vm_mem(msgvec.as_ptr().cast_mut(), &msgvec_value)?;
                if received == 0 {
                    return Err(e);
                }
                break;
            }
        }
    }

    if received > 0 {
        write_vm_mem(msgvec.as_ptr().cast_mut(), &msgvec_value)?;
    }
    Ok(received)
}
