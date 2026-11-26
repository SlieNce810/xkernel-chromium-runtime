// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Socket creation and management syscalls.
//!
//! This module implements socket operations including:
//! - Socket creation (socket, socketpair, etc.)
//! - Socket configuration (setsockopt, getsockopt, etc.)
//! - Socket binding and connection (bind, connect, listen, etc.)
//! - Socket shutdown (shutdown, etc.)

use alloc::{boxed::Box, sync::Arc};
use core::sync::atomic::{AtomicUsize, Ordering};

use kerrno::{KError, KResult, LinuxError};
#[cfg(feature = "vsock")]
use knet::vsock::{VsockSocket, VsockStreamTransport};
use knet::{
    AcceptOptions, ConnectOptions, Shutdown, Socket, SocketAddrEx, SocketOps,
    netlink::NetlinkSocket,
    packet::{PacketSocket, PacketSocketKind},
    raw::{IpProtocol, IpVersion, RawSocket},
    sock_alloc_file, sock_from_file,
    tcp::TcpSocket,
    udp::UdpSocket,
    unix::{DgramTransport, StreamTransport, UnixDomainSocket},
};
use linux_raw_sys::{
    general::{O_CLOEXEC, O_NONBLOCK, O_RDWR},
    net::{
        AF_INET, AF_INET6, AF_NETLINK, AF_PACKET, AF_UNIX, AF_VSOCK, IPPROTO_TCP, IPPROTO_UDP,
        SHUT_RD, SHUT_RDWR, SHUT_WR, SOCK_DGRAM, SOCK_RAW, SOCK_SEQPACKET, SOCK_STREAM, sockaddr,
        socklen_t,
    },
};
use posix_types::{UserConstPtr, UserPtr};

use crate::addr::SocketAddrExt;

// Narrow diagnostic window for Chromium bootstrap/network connect failures.
// Keep this bounded so normal score runs are not dominated by syscall logs.
static CHROMIUM_CONNECT_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);
static CHROMIUM_SOCKET_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);

fn chromium_socket_trace() -> Option<usize> {
    let argv = kprocess::current_user_process().cmdline().ok()?;
    if !argv.iter().any(|arg| arg.contains("/chromium")) {
        return None;
    }
    let seq = CHROMIUM_SOCKET_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    (seq < 256).then_some(seq)
}

fn chromium_connect_trace() -> Option<usize> {
    let argv = kprocess::current_user_process().cmdline().ok()?;
    if !argv.iter().any(|arg| arg.contains("/chromium")) {
        return None;
    }
    let seq = CHROMIUM_CONNECT_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    (seq < 128).then_some(seq)
}

fn socket_from_fd(fd: i32) -> KResult<Arc<Socket>> {
    let file = kprocess::current_resources().get_file(fd)?;
    sock_from_file(&file)
}

fn inet_raw_protocol(proto: u32) -> KResult<IpProtocol> {
    u8::try_from(proto)
        .map(IpProtocol::from)
        .map_err(|_| KError::from(LinuxError::EINVAL))
}

/// Create a new socket of the specified domain, type, and protocol
pub fn sys_socket(domain: u32, raw_ty: u32, proto: u32) -> KResult<isize> {
    let trace_seq = chromium_socket_trace();
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_SOCKET_CREATE seq={} pid={} domain={} raw_type={:#x} type={} proto={}",
            seq,
            kprocess::current_user_thread().pid(),
            domain,
            raw_ty,
            raw_ty & 0xff,
            proto);
    }
    // Extract the type bits (lower 8 bits, ignoring flags like SOCK_CLOEXEC)
    let ty = raw_ty & 0xFF;

    let pid = kprocess::current_user_thread().pid();
    let cred = kprocess::current_cred();
    // Create the appropriate socket type based on domain and type
    let socket = match (domain, ty) {
        (AF_INET, SOCK_STREAM) => {
            // TCP socket - verify protocol if specified
            if proto != 0 && proto != IPPROTO_TCP as u32 {
                return Err(KError::from(LinuxError::EPROTONOSUPPORT));
            }
            knet::Socket::Tcp(Box::new(TcpSocket::new()))
        }
        (AF_INET, SOCK_DGRAM) => {
            // UDP socket - verify protocol if specified
            if proto != 0 && proto != IPPROTO_UDP as u32 {
                return Err(KError::from(LinuxError::EPROTONOSUPPORT));
            }
            knet::Socket::Udp(Box::new(UdpSocket::new()))
        }
        (AF_INET, SOCK_RAW) => {
            // SOCK_RAW requires CAP_NET_RAW, matching Linux semantics.
            if !cred.is_privileged() {
                return Err(KError::from(LinuxError::EPERM));
            }
            let ip_proto = inet_raw_protocol(proto)?;
            knet::Socket::Raw(Box::new(RawSocket::new(IpVersion::Ipv4, ip_proto)))
        }
        // Chromium 149's NetworkService creates an IPv6 UDP socket during
        // startup even when the actual page is file://. Reuse the existing UDP
        // object for the creation probe; IPv6 address operations remain
        // separately validated by the socket address layer.
        (AF_INET6, SOCK_DGRAM) => {
            warn!("SANDBOX_SOCKET_IPV6_UDP_CREATE pid={} domain={} type={} proto={}", pid, domain, ty, proto);
            knet::Socket::Udp(Box::new(UdpSocket::new()))
        }
        // IPv6 stream/raw support is not implemented.
        (AF_INET6, _) => {
            warn!("SANDBOX_SOCKET_IPV6_UNSUPPORTED pid={} domain={} type={} proto={}", pid, domain, ty, proto);
            return Err(KError::from(LinuxError::EAFNOSUPPORT));
        }
        (AF_UNIX, SOCK_STREAM) => {
            // Unix domain stream socket
            knet::Socket::Unix(Box::new(UnixDomainSocket::new(StreamTransport::new(pid))))
        }
        (AF_UNIX, SOCK_SEQPACKET) => {
            // The current pathname listener/accept implementation is the
            // connection-oriented transport used by eudev control sockets.
            knet::Socket::Unix(Box::new(UnixDomainSocket::new(StreamTransport::new(pid))))
        }
        (AF_UNIX, SOCK_DGRAM) => {
            // Unix domain datagram socket
            knet::Socket::Unix(Box::new(UnixDomainSocket::new(DgramTransport::new(pid))))
        }
        (AF_NETLINK, SOCK_RAW) | (AF_NETLINK, SOCK_DGRAM) => {
            if proto > i32::MAX as u32 {
                return Err(KError::from(LinuxError::EPROTONOSUPPORT));
            }
            knet::Socket::Netlink(Box::new(NetlinkSocket::new(proto as i32)))
        }
        (AF_PACKET, SOCK_RAW) | (AF_PACKET, SOCK_DGRAM) => {
            if !cred.is_privileged() {
                return Err(KError::from(LinuxError::EPERM));
            }
            if proto > u16::MAX as u32 {
                return Err(KError::from(LinuxError::EPROTONOSUPPORT));
            }
            let kind = if ty == SOCK_RAW {
                PacketSocketKind::Raw
            } else {
                PacketSocketKind::Datagram
            };
            knet::Socket::Packet(Box::new(PacketSocket::new(kind, proto as u16)?))
        }
        #[cfg(feature = "vsock")]
        (AF_VSOCK, SOCK_STREAM) => {
            // Virtio socket (hypervisor communication)
            knet::Socket::Vsock(Box::new(VsockSocket::new(VsockStreamTransport::new())))
        }
        (AF_INET, _) | (AF_UNIX, _) | (AF_VSOCK, _) | (AF_NETLINK, _) | (AF_PACKET, _) => {
            // Socket type not supported for this domain
            warn!("Unsupported socket type: domain: {domain}, ty: {ty}");
            return Err(KError::from(LinuxError::ESOCKTNOSUPPORT));
        }
        _ => {
            // Address family not supported
            return Err(KError::from(LinuxError::EAFNOSUPPORT));
        }
    };
    let cloexec = raw_ty & O_CLOEXEC != 0;

    let file = sock_alloc_file(socket, O_RDWR | (raw_ty & O_NONBLOCK), cred)?;
    let result = kprocess::current_resources()
        .add_file(file, cloexec)
        .map(|fd| fd as isize);
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_SOCKET_RESULT seq={} pid={} result={:?}",
            seq, kprocess::current_user_thread().pid(), result);
    }
    result
}

/// Bind a socket to a local address
pub fn sys_bind(fd: i32, addr: UserConstPtr<sockaddr>, addrlen: u32) -> KResult<isize> {
    let addr = SocketAddrEx::read_from_user(addr, addrlen)?;

    socket_from_fd(fd)?.bind(addr)?;

    Ok(0)
}

/// Initiate a connection to a remote address
pub fn sys_connect(fd: i32, addr: UserConstPtr<sockaddr>, addrlen: u32) -> KResult<isize> {
    let addr = SocketAddrEx::read_from_user(addr, addrlen)?;
    let trace_seq = chromium_connect_trace();
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_CONNECT_CALL seq={} pid={} fd={} addr={:?}",
            seq, kprocess::current_user_thread().pid(), fd, addr);
    }

    let file = kprocess::current_resources().get_file(fd)?;
    let socket = sock_from_file(&file)?;
    let nonblocking = file.is_nonblocking();
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_CONNECT_MODE seq={} pid={} fd={} nonblocking={}",
            seq, kprocess::current_user_thread().pid(), fd, nonblocking);
    }
    let result = socket.connect(
        addr,
        ConnectOptions {
            nonblocking,
        },
    );
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_CONNECT_RESULT seq={} pid={} fd={} result={:?}",
            seq, kprocess::current_user_thread().pid(), fd, result);
    }
    result?;

    Ok(0)
}

/// Mark a socket as ready to accept incoming connections
pub fn sys_listen(fd: i32, backlog: i32) -> KResult<isize> {
    if backlog < 0 && backlog != -1 {
        return Err(KError::InvalidInput);
    }
    let backlog = if backlog == -1 {
        usize::MAX
    } else {
        backlog as usize
    };

    socket_from_fd(fd)?.listen(backlog)?;

    Ok(0)
}

/// Accept an incoming connection on a listening socket
pub fn sys_accept(fd: i32, addr: UserPtr<sockaddr>, addrlen: UserPtr<socklen_t>) -> KResult<isize> {
    sys_accept4(fd, addr, addrlen, 0)
}

/// Accept an incoming connection with additional flags (CLOEXEC, NONBLOCK)
pub fn sys_accept4(
    fd: i32,
    addr: UserPtr<sockaddr>,
    addrlen: UserPtr<socklen_t>,
    flags: u32,
) -> KResult<isize> {
    let cloexec = flags & O_CLOEXEC != 0;

    let file = kprocess::current_resources().get_file(fd)?;
    let socket = sock_from_file(&file)?;
    let socket = socket.accept(AcceptOptions {
        nonblocking: file.is_nonblocking(),
    })?;

    let remote_addr = socket.peer_addr()?;
    let file = sock_alloc_file(
        socket,
        O_RDWR | (flags & O_NONBLOCK),
        kprocess::current_cred(),
    )?;
    let fd = kprocess::current_resources()
        .add_file(file, cloexec)
        .map(|fd| fd as isize)?;

    if !addr.is_null() {
        let mut addrlen_value = addrlen.read_vm()?;
        remote_addr.write_to_user(addr, &mut addrlen_value)?;
        addrlen.write_vm(addrlen_value)?;
    }

    Ok(fd)
}

/// Shut down all or part of a full-duplex connection
pub fn sys_shutdown(fd: i32, how: u32) -> KResult<isize> {
    let socket = socket_from_fd(fd)?;
    let how = match how {
        SHUT_RD => Shutdown::Read,
        SHUT_WR => Shutdown::Write,
        SHUT_RDWR => Shutdown::Both,
        _ => return Err(KError::InvalidInput),
    };
    socket.shutdown(how).map(|_| 0)
}

/// Create a pair of connected sockets (Unix domain only)
pub fn sys_socketpair(
    domain: u32,
    raw_ty: u32,
    _proto: u32,
    fds: UserPtr<[i32; 2]>,
) -> KResult<isize> {
    let ty = raw_ty & 0xFF;
    let trace_seq = chromium_socket_trace();
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_SOCKETPAIR_CREATE seq={} pid={} domain={} raw_type={:#x} type={} proto={}",
            seq,
            kprocess::current_user_thread().pid(),
            domain,
            raw_ty,
            ty,
            _proto);
    }

    if domain != AF_UNIX {
        return Err(KError::from(LinuxError::EAFNOSUPPORT));
    }

    let pid = kprocess::current_user_thread().pid();
    let (sock1, sock2) = match ty {
        SOCK_STREAM => {
            let (sock1, sock2) = StreamTransport::new_pair(pid);
            (UnixDomainSocket::new(sock1), UnixDomainSocket::new(sock2))
        }
        SOCK_DGRAM | SOCK_SEQPACKET => {
            let (sock1, sock2) = DgramTransport::new_pair(pid);
            (UnixDomainSocket::new(sock1), UnixDomainSocket::new(sock2))
        }
        _ => {
            warn!("Unsupported socketpair type: {ty}");
            return Err(KError::from(LinuxError::ESOCKTNOSUPPORT));
        }
    };
    let sock1 = knet::Socket::Unix(Box::new(sock1));
    let sock2 = knet::Socket::Unix(Box::new(sock2));

    let cloexec = raw_ty & O_CLOEXEC != 0;
    let cred = kprocess::current_cred();
    let file1 = sock_alloc_file(sock1, O_RDWR | (raw_ty & O_NONBLOCK), cred.clone())?;
    let file2 = sock_alloc_file(sock2, O_RDWR | (raw_ty & O_NONBLOCK), cred)?;
    let resources = kprocess::current_resources();
    let fd1 = resources.add_file(file1, cloexec)?;
    let fd2 = resources.add_file(file2, cloexec).inspect_err(|_| {
        if let Err(err) = resources.close_file(fd1) {
            warn!("sys_socketpair cleanup failed for fd {fd1}: {err:?}");
        }
    })?;

    fds.write_vm([fd1, fd2])?;
    if let Some(seq) = trace_seq {
        warn!("CHROMIUM_SOCKETPAIR_RESULT seq={} pid={} type={} fd1={} fd2={}",
            seq, kprocess::current_user_thread().pid(), ty, fd1, fd2);
    }
    Ok(0)
}

#[cfg(unittest)]
mod tests {
    use unittest::{assert_eq, def_test};

    use super::*;

    #[def_test]
    fn inet_raw_protocol_rejects_values_above_u8() {
        assert_eq!(inet_raw_protocol(0).unwrap(), IpProtocol::from(0));
        assert_eq!(inet_raw_protocol(255).unwrap(), IpProtocol::from(255));
        assert_eq!(
            inet_raw_protocol(256).unwrap_err(),
            KError::from(LinuxError::EINVAL)
        );
    }
}
