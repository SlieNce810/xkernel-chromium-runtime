// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Control message handling for socket operations.
//!
//! This module provides parsing and handling of control messages (ancillary data)
//! in socket I/O operations, including file descriptor passing and other protocol-specific data.

use alloc::{sync::Arc, vec, vec::Vec};
use core::{mem::size_of, net::SocketAddr, ptr};

use bytemuck::{NoUninit, bytes_of};
use kerrno::{KError, KResult, LinuxError};
use knet::{SocketErrorInfo, SocketErrorOrigin, options::UnixCredentials};
use kvfs::VfsFile;
use linux_raw_sys::net::{
    AF_INET, AF_UNSPEC, IP_RECVERR, IPPROTO_IP, SCM_CREDENTIALS, SCM_RIGHTS, SOL_SOCKET, cmsghdr,
    in_addr, sockaddr_in, ucred,
};
use osvm::{VirtPtr, write_vm_mem};
use posix_types::{UserConstPtr, UserPtr};

#[repr(C)]
#[derive(Clone, Copy)]
struct SockExtendedErr {
    ee_errno: u32,
    ee_origin: u8,
    ee_type: u8,
    ee_code: u8,
    ee_pad: u8,
    ee_info: u32,
    ee_data: u32,
}

const _: [u8; 16] = [0; size_of::<SockExtendedErr>()];

// SAFETY: `SockExtendedErr` is a `repr(C)` Linux ABI structure made only of
// integer fields. Its field order is `u32, u8, u8, u8, u8, u32, u32`, which
// leaves no padding bytes; the size assertion above keeps this ABI expectation
// checked at compile time.
unsafe impl NoUninit for SockExtendedErr {}

const SO_EE_ORIGIN_LOCAL: u8 = 1;
const SO_EE_ORIGIN_ICMP: u8 = 2;
const SO_EE_ORIGIN_ICMP6: u8 = 3;
const SO_EE_ORIGIN_TXSTATUS: u8 = 4;

fn sock_extended_err_origin(origin: SocketErrorOrigin) -> u8 {
    match origin {
        SocketErrorOrigin::Local => SO_EE_ORIGIN_LOCAL,
        SocketErrorOrigin::Icmp => SO_EE_ORIGIN_ICMP,
        SocketErrorOrigin::Icmp6 => SO_EE_ORIGIN_ICMP6,
        SocketErrorOrigin::TxStatus => SO_EE_ORIGIN_TXSTATUS,
    }
}

fn write_sock_extended_err(data: &mut [u8], err: &SockExtendedErr) -> KResult<()> {
    if data.len() < size_of::<SockExtendedErr>() {
        return Err(KError::from(LinuxError::ENOBUFS));
    }
    data[..size_of::<SockExtendedErr>()].copy_from_slice(bytes_of(err));
    Ok(())
}

fn write_sockaddr_in(data: &mut [u8], addr: Option<SocketAddr>) -> KResult<()> {
    if data.len() < size_of::<sockaddr_in>() {
        return Err(KError::from(LinuxError::ENOBUFS));
    }
    let sa = match addr {
        Some(SocketAddr::V4(addr)) => sockaddr_in {
            sin_family: AF_INET as _,
            sin_port: addr.port().to_be(),
            sin_addr: in_addr {
                s_addr: u32::from_be_bytes(addr.ip().octets()).to_be(),
            },
            __pad: [0; 8],
        },
        _ => sockaddr_in {
            sin_family: AF_UNSPEC as _,
            sin_port: 0,
            sin_addr: in_addr { s_addr: 0 },
            __pad: [0; 8],
        },
    };

    // SAFETY: `sockaddr_in` is fully initialized above and `data` has been
    // checked to fit it at runtime. The ancillary payload is a byte slice, so its
    // address is not guaranteed to satisfy `sockaddr_in` alignment.
    unsafe {
        ptr::write_unaligned(data.as_mut_ptr().cast::<sockaddr_in>(), sa);
    }
    Ok(())
}

fn write_ip_recverr(
    data: &mut [u8],
    header: &SockExtendedErr,
    offender: Option<SocketAddr>,
) -> KResult<usize> {
    debug_assert_eq!(size_of::<SockExtendedErr>(), 16);
    debug_assert_eq!(size_of::<sockaddr_in>(), 16);

    let body_len = size_of::<SockExtendedErr>() + size_of::<sockaddr_in>();
    if data.len() < body_len {
        return Err(KError::from(LinuxError::ENOBUFS));
    }

    let (err_buf, addr_buf) = data[..body_len].split_at_mut(size_of::<SockExtendedErr>());
    write_sock_extended_err(err_buf, header)?;
    write_sockaddr_in(addr_buf, offender)?;
    Ok(body_len)
}

pub(crate) fn push_ip_recverr_cmsg(
    builder: &mut CMsgBuilder<'_>,
    err: SocketErrorInfo,
) -> KResult<bool> {
    builder.push(IPPROTO_IP as u32, IP_RECVERR, |data| {
        let header = SockExtendedErr {
            ee_errno: err.errno.into_raw() as u32,
            ee_origin: sock_extended_err_origin(err.origin),
            ee_type: err.error_type,
            ee_code: err.error_code,
            ee_pad: 0,
            ee_info: err.info,
            ee_data: err.data,
        };

        write_ip_recverr(data, &header, err.offender)
    })
}

/// Control message types for socket operations (ancillary data)
pub(crate) enum CMsg {
    /// SCM_RIGHTS: file descriptor passing between processes
    Rights { fds: Vec<Arc<VfsFile>> },
    /// SCM_CREDENTIALS: the sender's credentials, attached to one message
    Credentials { cred: UnixCredentials },
}

/// Return the Linux CMSG_SPACE size for a cmsg_len value.
pub(crate) fn cmsg_space_len(cmsg_len: usize) -> KResult<usize> {
    let align = core::mem::align_of::<cmsghdr>();
    let mask = align.saturating_sub(1);
    cmsg_len
        .checked_add(mask)
        .map(|value| value & !mask)
        .ok_or(KError::InvalidInput)
}
impl CMsg {
    /// Parse a control message header and extract its data
    pub(crate) fn parse(
        resources: &kresources::ProcessResources,
        hdr_ptr: UserConstPtr<cmsghdr>,
        hdr: cmsghdr,
    ) -> KResult<Self> {
        if hdr.cmsg_len < size_of::<cmsghdr>() {
            return Err(KError::InvalidInput);
        }

        let data = UserConstPtr::<u8>::from(hdr_ptr.as_ptr() as usize + size_of::<cmsghdr>())
            .load_vm_vec(hdr.cmsg_len - size_of::<cmsghdr>())?;
        Ok(match (hdr.cmsg_level as u32, hdr.cmsg_type as u32) {
            (SOL_SOCKET, SCM_RIGHTS) => {
                if data.len() % size_of::<i32>() != 0 {
                    return Err(KError::InvalidInput);
                }
                let mut fds = Vec::new();
                for fd in data.chunks_exact(size_of::<i32>()) {
                    let fd = i32::from_ne_bytes(fd.try_into().unwrap());
                    if fd < 0 {
                        return Err(KError::BadFileDescriptor);
                    }
                    let f = resources.get_file(fd)?;
                    fds.push(f);
                }
                Self::Rights { fds }
            }
            (SOL_SOCKET, SCM_CREDENTIALS) => {
                // Linux requires the payload to be exactly one `struct ucred`
                // (`scm_send`): any other length is EINVAL.
                if data.len() != size_of::<ucred>() {
                    return Err(KError::InvalidInput);
                }
                let claimed = ucred {
                    pid: u32::from_ne_bytes(data[0..4].try_into().unwrap()),
                    uid: u32::from_ne_bytes(data[4..8].try_into().unwrap()),
                    gid: u32::from_ne_bytes(data[8..12].try_into().unwrap()),
                };
                // `scm_check_creds`: a sender may only claim its own identity.
                // Anything else needs CAP_SYS_ADMIN, otherwise EPERM.
                let cred = kprocess::current_cred();
                let privileged = cred.is_privileged();
                let pid_ok = privileged || claimed.pid == kprocess::current_user_thread().pid();
                let uid_ok = privileged || claimed.uid == cred.euid();
                let gid_ok = privileged || claimed.gid == cred.egid();
                if !(pid_ok && uid_ok && gid_ok) {
                    return Err(KError::from(LinuxError::EPERM));
                }
                Self::Credentials {
                    cred: UnixCredentials {
                        pid: claimed.pid,
                        uid: claimed.uid,
                        gid: claimed.gid,
                    },
                }
            }
            _ => {
                return Err(KError::InvalidInput);
            }
        })
    }
}

/// Builder for constructing control message buffers for socket I/O
pub(crate) struct CMsgBuilder<'a> {
    hdr: UserPtr<cmsghdr>,
    len: &'a mut usize,
    capacity: usize,
}
impl<'a> CMsgBuilder<'a> {
    /// Create a new control message builder with a given buffer and capacity
    pub(crate) fn new(msg: UserPtr<cmsghdr>, len: &'a mut usize) -> Self {
        let capacity = *len;
        *len = 0;
        Self {
            hdr: msg,
            len,
            capacity,
        }
    }

    /// Add a control message with the specified level and type to the buffer
    pub(crate) fn push(
        &mut self,
        level: u32,
        ty: u32,
        body: impl FnOnce(&mut [u8]) -> KResult<usize>,
    ) -> KResult<bool> {
        let Some(remaining) = self.capacity.checked_sub(*self.len) else {
            return Ok(false);
        };
        let Some(body_capacity) = remaining.checked_sub(size_of::<cmsghdr>()) else {
            return Ok(false);
        };

        let mut data = vec![0u8; body_capacity];
        let body_len = body(&mut data)?;

        let cmsg_len = size_of::<cmsghdr>() + body_len;
        let cmsg_space = cmsg_space_len(cmsg_len)?;
        if cmsg_space > remaining {
            return Ok(false);
        }
        UserPtr::<u8>::from(self.hdr.as_ptr() as usize + size_of::<cmsghdr>())
            .write_vm_slice(&data[..body_len])?;

        let hdr = cmsghdr {
            cmsg_len,
            cmsg_level: level as _,
            cmsg_type: ty as _,
        };
        write_vm_mem(self.hdr.as_ptr().cast_mut(), core::slice::from_ref(&hdr))?;

        let padding = cmsg_space - cmsg_len;
        if padding != 0 {
            UserPtr::<u8>::from(self.hdr.as_ptr() as usize + cmsg_len)
                .write_vm_slice(&vec![0; padding])?;
        }
        self.hdr = UserPtr::from(self.hdr.as_ptr() as usize + cmsg_space);
        *self.len += cmsg_space;
        Ok(true)
    }
}

#[cfg(unittest)]
mod tests {
    use unittest::def_test;

    use super::*;

    #[def_test]
    fn test_sock_extended_err_origin_matches_linux_abi() {
        assert_eq!(
            sock_extended_err_origin(SocketErrorOrigin::Local),
            SO_EE_ORIGIN_LOCAL
        );
        assert_eq!(
            sock_extended_err_origin(SocketErrorOrigin::Icmp),
            SO_EE_ORIGIN_ICMP
        );
        assert_eq!(
            sock_extended_err_origin(SocketErrorOrigin::Icmp6),
            SO_EE_ORIGIN_ICMP6
        );
        assert_eq!(
            sock_extended_err_origin(SocketErrorOrigin::TxStatus),
            SO_EE_ORIGIN_TXSTATUS
        );
    }
}
