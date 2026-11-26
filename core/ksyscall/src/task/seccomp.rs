// SPDX-License-Identifier: Apache-2.0
//! Classic BPF installation and syscall action handling for seccomp.

use alloc::vec::Vec;

use kerrno::{KError, KResult, LinuxError};
use kprocess::{current_user_thread, seccomp_cbpf};
use osvm::VirtPtr;

use kprocess::seccomp_cbpf::{
    ACTION_MASK, Insn, RET_ALLOW, RET_ERRNO, RET_KILL_PROCESS,
    RET_KILL_THREAD, RET_LOG, RET_TRACE, RET_TRAP, SeccompData, VerifiedProgram,
};

const SECCOMP_SET_MODE_STRICT: u32 = 0;
const SECCOMP_SET_MODE_FILTER: u32 = 1;
const SECCOMP_GET_ACTION_AVAIL: u32 = 2;
const FILTER_FLAG_TSYNC: u32 = 1;
const FILTER_FLAG_LOG: u32 = 2;
const FILTER_FLAG_SPEC_ALLOW: u32 = 4;
const FILTER_FLAG_NEW_LISTENER: u32 = 8;
const FILTER_FLAG_TSYNC_ESRCH: u32 = 16;
const MAX_FILTER_LEN: usize = 4096;
const MAX_ERRNO: u32 = 4095;

/// `sock_fprog` uses a u16 length followed by a naturally aligned pointer.
#[repr(C)]
#[derive(Clone, Copy)]
struct SockFprog {
    len: u16,
    filter: usize,
}

/// Install and retain one validated seccomp classic BPF filter.
pub fn install_filter(program_pointer: *const (), flags: u32) -> KResult<isize> {
    if program_pointer.is_null() {
        return Err(KError::BadAddress);
    }
    if flags & !(FILTER_FLAG_LOG | FILTER_FLAG_SPEC_ALLOW | FILTER_FLAG_TSYNC
        | FILTER_FLAG_NEW_LISTENER | FILTER_FLAG_TSYNC_ESRCH) != 0
    {
        return Err(KError::InvalidInput);
    }
    if flags & (FILTER_FLAG_TSYNC | FILTER_FLAG_NEW_LISTENER | FILTER_FLAG_TSYNC_ESRCH) != 0 {
        // These flags require atomic process-wide thread synchronization or a
        // listener descriptor. Neither is implemented yet, so fail closed.
        return Err(KError::Unsupported);
    }

    let thread = current_user_thread();
    if !thread.no_new_privileges() && thread.capabilities_empty() {
        return Err(KError::PermissionDenied);
    }
    if thread.seccomp_mode() == 1 {
        return Err(KError::PermissionDenied);
    }

    let fprog_address = program_pointer as usize;
    let length = (fprog_address as *const u16).read_vm()? as usize;
    let filter_field_address = fprog_address
        .checked_add(core::mem::offset_of!(SockFprog, filter))
        .ok_or(KError::BadAddress)?;
    let filter_pointer = (filter_field_address as *const usize).read_vm()? as *const Insn;
    if length == 0 || length > MAX_FILTER_LEN || filter_pointer.is_null() {
        return Err(KError::InvalidInput);
    }
    let mut instructions = Vec::with_capacity(length);
    for index in 0..length {
        let byte_offset = index.checked_mul(core::mem::size_of::<Insn>())
            .ok_or(KError::BadAddress)?;
        let address = (filter_pointer as usize)
            .checked_add(byte_offset)
            .ok_or(KError::BadAddress)?;
        let jt_address = address.checked_add(2).ok_or(KError::BadAddress)?;
        let jf_address = address.checked_add(3).ok_or(KError::BadAddress)?;
        let immediate_address = address.checked_add(4).ok_or(KError::BadAddress)?;
        instructions.push(Insn {
            code: (address as *const u16).read_vm()?,
            jt: (jt_address as *const u8).read_vm()?,
            jf: (jf_address as *const u8).read_vm()?,
            k: (immediate_address as *const u32).read_vm()?,
        });
    }

    let program = VerifiedProgram::new(instructions).map_err(|error| {
        warn!("SECCOMP_BPF_REJECT pid={} len={} error={:?}", thread.pid(), length, error);
        KError::InvalidInput
    })?;
    thread.append_seccomp_filter(program)?;
    warn!("SECCOMP_BPF_INSTALLED pid={} flags={} len={}", thread.pid(), flags, length);
    Ok(0)
}

/// Implement the `seccomp(2)` operation subset needed for filter installation.
pub fn sys_seccomp(operation: u32, flags: u32, args: *const ()) -> KResult<isize> {
    match operation {
        SECCOMP_SET_MODE_STRICT => Err(KError::Unsupported),
        SECCOMP_SET_MODE_FILTER => install_filter(args, flags),
        SECCOMP_GET_ACTION_AVAIL => {
            if flags != 0 { return Err(KError::InvalidInput); }
            if args.is_null() { return Err(KError::BadAddress); }
            let action = (args as *const u32).read_vm()?;
            if seccomp_cbpf::action_is_supported(action) {
                Ok(0)
            } else {
                Err(KError::from(LinuxError::EOPNOTSUPP))
            }
        }
        _ => Err(KError::from(LinuxError::EINVAL)),
    }
}

/// Return the current thread's filter result, or `None` when seccomp is off.
pub fn evaluate(data: &SeccompData) -> Option<u32> {
    let thread = current_user_thread();
    match thread.seccomp_mode() {
        0 => None,
        1 => {
            strict_mode_allows(data.nr).then_some(RET_ALLOW).or(Some(RET_KILL_PROCESS))
        }
        2 => Some(thread.seccomp_filter_chain()
            .map(|chain| chain.run(data))
            .unwrap_or(RET_KILL_PROCESS)),
        _ => Some(RET_KILL_PROCESS),
    }
}

/// Linux strict mode permits only read, write, sigreturn and process exit.
#[cfg(target_arch = "aarch64")]
fn strict_mode_allows(nr: i32) -> bool { matches!(nr, 63 | 64 | 93 | 139) }
#[cfg(target_arch = "x86_64")]
fn strict_mode_allows(nr: i32) -> bool { matches!(nr, 0 | 1 | 15 | 60 | 231) }
#[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
fn strict_mode_allows(_nr: i32) -> bool { false }

/// Split a filter return into action and data.
pub fn action(result: u32) -> (u32, u16) {
    (result & ACTION_MASK, result as u16)
}

/// Convert `SECCOMP_RET_ERRNO` data to a Linux errno.
pub fn errno_value(data: u16) -> u32 {
    let value = (data as u32).min(MAX_ERRNO);
    if value == 0 { LinuxError::ENOSYS.into_raw() as u32 } else { value }
}

/// Decode a syscall number from strict-mode's fixed allow list.
#[cfg(target_arch = "aarch64")]
pub const fn seccomp_syscall_arch() -> u32 { 0xc000_00b7 }
#[cfg(target_arch = "x86_64")]
pub const fn seccomp_syscall_arch() -> u32 { 0xc000_003e }
#[cfg(target_arch = "riscv64")]
pub const fn seccomp_syscall_arch() -> u32 { 0xc000_00f3 }
#[cfg(target_arch = "loongarch64")]
pub const fn seccomp_syscall_arch() -> u32 { 0xc000_0102 }

/// Constants re-exported for syscall dispatch.
pub const ACTION_ALLOW: u32 = RET_ALLOW;
pub const ACTION_LOG: u32 = RET_LOG;
pub const ACTION_ERRNO: u32 = RET_ERRNO;
pub const ACTION_TRACE: u32 = RET_TRACE;
pub const ACTION_TRAP: u32 = RET_TRAP;
pub const ACTION_KILL_THREAD: u32 = RET_KILL_THREAD;
pub const ACTION_KILL_PROCESS: u32 = RET_KILL_PROCESS;

/// Construct the audit architecture tag for the running kernel ABI.
#[cfg(target_arch = "aarch64")]
pub const fn audit_arch() -> u32 { 0xc000_00b7 }
#[cfg(target_arch = "x86_64")]
pub const fn audit_arch() -> u32 { 0xc000_003e }
#[cfg(target_arch = "riscv64")]
pub const fn audit_arch() -> u32 { 0xc000_00f3 }
#[cfg(target_arch = "loongarch64")]
pub const fn audit_arch() -> u32 { 0xc000_0102 }
