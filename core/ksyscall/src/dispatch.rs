// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Syscall implementation and dispatch.
//!
//! This module is the core of the syscall interface. It dispatches system calls from user space
//! to the appropriate handler functions based on the syscall number.
//!
//! The module is organized into submodules for different categories:
//! - `vfs`: VFS/path-based operations
//! - `ipc`: IPC descriptor operations
//! - `io_mpx`: I/O multiplexing (select, poll, epoll)
//! - `mm`: Memory management
//! - `posix-net`: Network operations
//! - `sync`: Synchronization primitives
//! - `sys`: System information and control
//! - `task`: Process, thread, signal, and pidfd management
//! - `time`: Time and process-timer operations

#[cfg(target_arch = "riscv64")]
use kerrno::KResult;
use kerrno::LinuxError;
use khal::uspace::UserContext;
use kprocess::UserThreadRuntimeAction;
use linux_sysno::Sysno;
use posix_ipc::*;
use posix_mm::*;
use posix_net::*;

use crate::{io_mpx::*, ipc::*, sync::*, sys::*, task::*, time::*, vfs::*};

/// `riscv_flush_icache(start, end, flags)` — synchronize the instruction cache.
///
/// The address range is ignored, matching Linux. `flags` selects the scope:
/// [`SYS_RISCV_FLUSH_ICACHE_LOCAL`] flushes only the current hart (a single
/// `fence.i`); otherwise the flush is broadcast to every hart via IPI so that
/// self-modifying code stays visible after the task migrates. Reserved flag
/// bits are rejected with [`EINVAL`], matching Linux
/// `flags & ~SYS_RISCV_FLUSH_ICACHE_ALL` (the ABI declares `flags` as
/// `uintptr_t`, so high bits participate in the check).
///
/// [`EINVAL`]: LinuxError::EINVAL
#[cfg(target_arch = "riscv64")]
fn sys_riscv_flush_icache(flags: usize) -> KResult<isize> {
    const SYS_RISCV_FLUSH_ICACHE_LOCAL: usize = 1;
    if flags & !SYS_RISCV_FLUSH_ICACHE_LOCAL != 0 {
        return Err(LinuxError::EINVAL.into());
    }
    if flags & SYS_RISCV_FLUSH_ICACHE_LOCAL != 0 {
        karch::flush_icache_all_local();
    } else {
        karch::flush_icache_all();
    }
    Ok(0)
}

/// Dispatches the syscall number and raw arguments in `uctx` for the current thread.
///
/// # Arguments
///
/// `uctx` must be the current user thread's exclusively borrowed trap context.
/// The runtime must have established current process/thread state, address-space
/// access, scheduler, allocator, and subsystem initialization. Despite the name,
/// this is a syscall thread path: handlers can block, allocate, replace the user
/// context on exec, or terminate the thread. Do not invoke from a hardware IRQ,
/// early boot, or while holding locks that prohibit sleeping.
///
/// # Returns
///
/// Writes the result register, encoding ordinary failures as negative Linux
/// errno (including `ENOSYS` for unknown/unsupported calls). Enabled TEE/TIPC
/// extensions retain their own status conventions. Returns `Continue`, or
/// `SkipSignalCheckOnce` after successful `rt_sigreturn`. The caller performs
/// the runtime action; dispatch itself does not enter user mode.
///
/// # Panics
///
/// Handler access to missing current process/thread state or uninitialized
/// providers can panic. Allocation failure follows kernel allocator policy.
pub fn dispatch_irq_syscall(uctx: &mut UserContext) -> UserThreadRuntimeAction {
    let raw_sysno = uctx.sysno();
    if let Some(filter_result) = crate::task::seccomp::evaluate(&kprocess::seccomp_cbpf::SeccompData {
        nr: raw_sysno as i32,
        arch: crate::task::seccomp::audit_arch(),
        instruction_pointer: uctx.ip() as u64,
        args: [uctx.arg0() as u64, uctx.arg1() as u64, uctx.arg2() as u64,
               uctx.arg3() as u64, uctx.arg4() as u64, uctx.arg5() as u64],
    }) {
        let (action, data) = crate::task::seccomp::action(filter_result);
        match action {
            crate::task::seccomp::ACTION_ALLOW => {}
            crate::task::seccomp::ACTION_LOG => {
                debug!("SECCOMP_LOG pid={} sysno={}", kprocess::current_user_thread().pid(), raw_sysno);
            }
            crate::task::seccomp::ACTION_ERRNO => {
                let errno = crate::task::seccomp::errno_value(data);
                uctx.set_retval((-(errno as isize)) as _);
                return UserThreadRuntimeAction::Continue;
            }
            crate::task::seccomp::ACTION_TRACE => {
                uctx.set_retval(-(LinuxError::ENOSYS.into_raw() as isize) as _);
                return UserThreadRuntimeAction::Continue;
            }
            crate::task::seccomp::ACTION_TRAP => {
                uctx.set_retval(-(LinuxError::ENOSYS.into_raw() as isize) as _);
                let info = ksignal::SignalInfo::new_seccomp(
                    raw_sysno as i32,
                    crate::task::seccomp::audit_arch(),
                    uctx.ip(),
                    data,
                );
                posix_process::raise_signal_fatal(info)
                    .expect("failed to deliver seccomp SIGSYS");
                return UserThreadRuntimeAction::Continue;
            }
            crate::task::seccomp::ACTION_KILL_THREAD => {
                posix_process::do_exit(ksignal::Signo::SIGSYS as i32, false);
                return UserThreadRuntimeAction::Continue;
            }
            crate::task::seccomp::ACTION_KILL_PROCESS => {
                posix_process::do_exit(ksignal::Signo::SIGSYS as i32, true);
                return UserThreadRuntimeAction::Continue;
            }
            _ => {
                posix_process::do_exit(ksignal::Signo::SIGSYS as i32, true);
                return UserThreadRuntimeAction::Continue;
            }
        }
    }

    let Some(sysno) = Sysno::new(raw_sysno) else {
        warn!("Invalid syscall number: {}", raw_sysno);
        uctx.set_retval(-LinuxError::ENOSYS.into_raw() as _);
        return UserThreadRuntimeAction::Continue;
    };

    trace!("Syscall {sysno:?}");
    let result = match sysno {
        // fs ctl
        Sysno::ioctl => {
            let fd = uctx.arg0() as i32;
            let cmd = uctx.arg1() as u32;
            let arg = uctx.arg2();
            // Ask posix-net by exact SIOC* command, not the 0x89xx type
            // space. Unrecognized commands fall through to the file ioctl.
            match handle_net_ioctl(fd, cmd, arg).transpose() {
                Some(result) => result,
                None => sys_ioctl(fd, cmd, arg),
            }
        }
        Sysno::chdir => sys_chdir(uctx.arg0().into()),
        Sysno::fchdir => sys_fchdir(uctx.arg0() as _),
        Sysno::chroot => sys_chroot(uctx.arg0().into()),
        #[cfg(target_arch = "x86_64")]
        Sysno::mkdir => sys_mkdir(uctx.arg0().into(), uctx.arg1() as _),
        Sysno::mkdirat => sys_mkdirat(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::mknod => sys_mknod(uctx.arg0().into(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::mknodat => sys_mknodat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::getdents64 => sys_getdents64(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::link => sys_link(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::linkat => sys_linkat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),
        #[cfg(target_arch = "x86_64")]
        Sysno::rmdir => sys_rmdir(uctx.arg0().into()),
        #[cfg(target_arch = "x86_64")]
        Sysno::unlink => sys_unlink(uctx.arg0().into()),
        Sysno::unlinkat => sys_unlinkat(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::getcwd => sys_getcwd(uctx.arg0().into(), uctx.arg1() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::symlink => sys_symlink(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::symlinkat => sys_symlinkat(uctx.arg0().into(), uctx.arg1() as _, uctx.arg2().into()),
        #[cfg(target_arch = "x86_64")]
        Sysno::rename => sys_rename(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::renameat => sys_renameat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3().into(),
        ),
        Sysno::renameat2 => sys_renameat2(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),
        Sysno::sync => sys_sync(),
        Sysno::syncfs => sys_syncfs(uctx.arg0() as _),

        // file ops
        #[cfg(target_arch = "x86_64")]
        Sysno::chown => sys_chown(uctx.arg0().into(), uctx.arg1() as _, uctx.arg2() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::lchown => sys_lchown(uctx.arg0().into(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::fchown => sys_fchown(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::fchownat => sys_fchownat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        #[cfg(target_arch = "x86_64")]
        Sysno::chmod => sys_chmod(uctx.arg0().into(), uctx.arg1() as _),
        Sysno::fchmod => sys_fchmod(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::fchmodat | Sysno::fchmodat2 => sys_fchmodat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        #[cfg(target_arch = "x86_64")]
        Sysno::readlink => sys_readlink(uctx.arg0().into(), uctx.arg1().into(), uctx.arg2() as _),
        Sysno::readlinkat => sys_readlinkat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        #[cfg(target_arch = "x86_64")]
        Sysno::utime => sys_utime(uctx.arg0().into(), uctx.arg1().into()),
        #[cfg(target_arch = "x86_64")]
        Sysno::utimes => sys_utimes(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::utimensat => sys_utimensat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::setxattr => sys_setxattr(
            uctx.arg0().into(),
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::lsetxattr => sys_lsetxattr(
            uctx.arg0().into(),
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::fsetxattr => sys_fsetxattr(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::getxattr => sys_getxattr(
            uctx.arg0().into(),
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::lgetxattr => sys_lgetxattr(
            uctx.arg0().into(),
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::fgetxattr => sys_fgetxattr(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::listxattr => sys_listxattr(uctx.arg0().into(), uctx.arg1().into(), uctx.arg2() as _),
        Sysno::llistxattr => {
            sys_llistxattr(uctx.arg0().into(), uctx.arg1().into(), uctx.arg2() as _)
        }
        Sysno::flistxattr => sys_flistxattr(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::removexattr => sys_removexattr(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::lremovexattr => sys_lremovexattr(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::fremovexattr => sys_fremovexattr(uctx.arg0() as _, uctx.arg1().into()),

        // fd ops
        #[cfg(target_arch = "x86_64")]
        Sysno::open => sys_open(uctx.arg0().into(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::openat => sys_openat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::close => sys_close(uctx.arg0() as _),
        Sysno::close_range => sys_close_range(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::dup => sys_dup(uctx.arg0() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::dup2 => sys_dup2(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::dup3 => sys_dup3(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::fcntl => sys_fcntl(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::flock => sys_flock(uctx.arg0() as _, uctx.arg1() as _),

        // io
        Sysno::read => sys_read(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::readv => sys_readv(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::write => sys_write(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::writev => sys_writev(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::lseek => sys_lseek(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::truncate => sys_truncate(uctx.arg0().into(), uctx.arg1() as _),
        Sysno::ftruncate => sys_ftruncate(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::fallocate => sys_fallocate(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::fsync => sys_fsync(uctx.arg0() as _),
        Sysno::fdatasync => sys_fdatasync(uctx.arg0() as _),
        Sysno::fadvise64 => sys_fadvise64(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::pread64 => sys_pread64(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::pwrite64 => sys_pwrite64(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::preadv => sys_preadv(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::pwritev => sys_pwritev(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::preadv2 => sys_preadv2(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::pwritev2 => sys_pwritev2(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::sendfile => sys_sendfile(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::copy_file_range => sys_copy_file_range(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
            uctx.arg5() as _,
        ),
        Sysno::splice => sys_splice(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
            uctx.arg5() as _,
        ),

        // io mpx
        #[cfg(target_arch = "x86_64")]
        Sysno::poll => sys_poll(uctx.arg0().into(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::ppoll => sys_ppoll(
            uctx.arg0().into(),
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),
        #[cfg(any(
            target_arch = "aarch64",
            target_arch = "riscv64",
            target_arch = "loongarch64"
        ))]
        Sysno::ppoll_time64 => sys_ppoll(
            uctx.arg0().into(),
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),
        #[cfg(target_arch = "x86_64")]
        Sysno::select => sys_select(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3().into(),
            uctx.arg4().into(),
        ),
        Sysno::pselect6 => sys_pselect6(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3().into(),
            uctx.arg4().into(),
            uctx.arg5().into(),
        ),
        Sysno::epoll_create1 => sys_epoll_create1(uctx.arg0() as _),
        Sysno::epoll_ctl => sys_epoll_ctl(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
        ),
        Sysno::epoll_pwait => sys_epoll_pwait(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4().into(),
            uctx.arg5() as _,
        ),
        Sysno::epoll_pwait2 => sys_epoll_pwait2(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4().into(),
            uctx.arg5() as _,
        ),

        // fs mount
        Sysno::mount => sys_mount(
            uctx.arg0().into(),
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
            uctx.arg4().into(),
        ) as _,
        Sysno::umount2 => sys_umount2(uctx.arg0().into(), uctx.arg1() as _) as _,

        // pipe
        Sysno::pipe2 => sys_pipe2(uctx.arg0().into(), uctx.arg1() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::pipe => sys_pipe2(uctx.arg0().into(), 0),

        // event
        Sysno::eventfd2 => sys_eventfd2(uctx.arg0() as _, uctx.arg1() as _),

        // pidfd
        Sysno::pidfd_open => sys_pidfd_open(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::pidfd_getfd => sys_pidfd_getfd(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::pidfd_send_signal => sys_pidfd_send_signal(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),

        // memfd
        Sysno::memfd_create => {
            let flags = uctx.arg1() as u32;
            warn!("SANDBOX_MEMFD_CREATE_REQUEST flags={:#x}", flags);
            sys_memfd_create(uctx.arg0().into(), flags)
        },

        // fs stat
        #[cfg(target_arch = "x86_64")]
        Sysno::stat => sys_stat(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::fstat => sys_fstat(uctx.arg0() as _, uctx.arg1().into()),
        #[cfg(target_arch = "x86_64")]
        Sysno::lstat => sys_lstat(uctx.arg0().into(), uctx.arg1().into()),
        #[cfg(target_arch = "x86_64")]
        Sysno::newfstatat => sys_fstatat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        #[cfg(not(target_arch = "x86_64"))]
        Sysno::fstatat => sys_fstatat(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::statx => sys_statx(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4().into(),
        ),
        #[cfg(target_arch = "x86_64")]
        Sysno::access => sys_access(uctx.arg0().into(), uctx.arg1() as _),
        Sysno::faccessat => sys_faccessat(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::faccessat2 => sys_faccessat2(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::statfs => sys_statfs(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::fstatfs => sys_fstatfs(uctx.arg0() as _, uctx.arg1().into()),

        // mm
        Sysno::brk => sys_brk(uctx.arg0() as _),
        Sysno::mmap => sys_mmap(
            uctx.arg0(),
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
            uctx.arg5() as _,
        ),
        Sysno::munmap => sys_munmap(uctx.arg0(), uctx.arg1() as _),
        Sysno::mprotect => sys_mprotect(uctx.arg0(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::mincore => sys_mincore(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2().into()),
        Sysno::mremap => {
            let addr = uctx.arg0();
            let old_size = uctx.arg1() as usize;
            let new_size = uctx.arg2() as usize;
            let flags = uctx.arg3() as u32;
            let new_addr = uctx.arg4();
            warn!("SANDBOX_MREMAP_REQUEST addr={:#x} old_size={:#x} new_size={:#x} flags={:#x} new_addr={:#x}", addr, old_size, new_size, flags, new_addr);
            sys_mremap(addr, old_size, new_size, flags, new_addr)
        },
        Sysno::madvise => sys_madvise(uctx.arg0(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::msync => sys_msync(uctx.arg0(), uctx.arg1() as _, uctx.arg2() as _),
        Sysno::mlock => sys_mlock(uctx.arg0(), uctx.arg1() as _),
        Sysno::mlock2 => sys_mlock2(uctx.arg0(), uctx.arg1() as _, uctx.arg2() as _),

        // task info
        Sysno::getpid => sys_getpid(),
        Sysno::getppid => sys_getppid(),
        Sysno::gettid => sys_gettid(),
        Sysno::getrusage => sys_getrusage(uctx.arg0() as _, uctx.arg1().into()),

        // task sched
        Sysno::sched_yield => sys_sched_yield(),
        Sysno::nanosleep => sys_nanosleep(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::clock_nanosleep => sys_clock_nanosleep(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3().into(),
        ),
        Sysno::sched_getaffinity => {
            sys_sched_getaffinity(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2().into())
        }
        Sysno::sched_setaffinity => {
            sys_sched_setaffinity(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2().into())
        }
        Sysno::sched_getscheduler => sys_sched_getscheduler(uctx.arg0() as _),
        Sysno::sched_setscheduler => {
            sys_sched_setscheduler(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2().into())
        }
        Sysno::sched_getparam => sys_sched_getparam(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::sched_setparam => sys_sched_setparam(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::getcpu => sys_getcpu(uctx.arg0().into(), uctx.arg1().into(), uctx.arg2()),
        Sysno::getpriority => sys_getpriority(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::setpriority => sys_setpriority(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),

        // task ops
        Sysno::execve => sys_execve(uctx, uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::set_tid_address => sys_set_tid_address(uctx.arg0()),
        #[cfg(target_arch = "x86_64")]
        Sysno::arch_prctl => sys_arch_prctl(uctx, uctx.arg0() as _, uctx.arg1() as _),
        Sysno::prctl => sys_prctl(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::prlimit64 => {
            let pid = uctx.arg0() as usize;
            let resource = uctx.arg1() as u32;
            let new_limit = uctx.arg2();
            let old_limit = uctx.arg3();
            warn!("SANDBOX_PRLIMIT_REQUEST pid={} resource={} new_limit={:#x} old_limit={:#x}", pid, resource, new_limit, old_limit);
            sys_prlimit64(pid as _, resource, new_limit.into(), old_limit.into())
        },
        Sysno::getrlimit => sys_getrlimit(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::setrlimit => sys_setrlimit(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::capget => sys_capget(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::capset => sys_capset(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::umask => sys_umask(uctx.arg0() as _),
        Sysno::setreuid => sys_setreuid(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::setregid => sys_setregid(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::setresuid => sys_setresuid(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::setresgid => sys_setresgid(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::get_mempolicy => sys_get_mempolicy(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),

        // task management
        Sysno::clone => {
            warn!("SANDBOX_SYSCALL clone flags={:#x} stack={:#x} ptid={:#x} ctid={:#x} tls={:#x}",
                uctx.arg0(), uctx.arg1(), uctx.arg2(), uctx.arg3(), uctx.arg4());
            sys_clone(
                uctx,
                uctx.arg0() as _,
                uctx.arg1() as _,
                uctx.arg2(),
                uctx.arg3(),
                uctx.arg4(),
            )
        }
        Sysno::clone3 => {
            warn!("SANDBOX_SYSCALL clone3 args={:#x} size={:#x}", uctx.arg0(), uctx.arg1());
            sys_clone3(uctx, uctx.arg0(), uctx.arg1())
        }
        Sysno::unshare => sys_unshare(uctx.arg0() as u64),
        Sysno::setns => sys_setns(uctx.arg0() as _, uctx.arg1() as _),
        #[cfg(target_arch = "x86_64")]
        Sysno::fork => sys_fork(uctx),
        #[cfg(target_arch = "x86_64")]
        Sysno::vfork => sys_vfork(uctx),
        Sysno::exit => sys_exit(uctx.arg0() as _),
        Sysno::exit_group => sys_exit_group(uctx.arg0() as _),
        Sysno::wait4 => sys_waitpid(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::getsid => sys_getsid(uctx.arg0() as i32),
        Sysno::setsid => sys_setsid(),
        Sysno::getpgid => sys_getpgid(uctx.arg0() as i32),
        #[cfg(target_arch = "x86_64")]
        Sysno::getpgrp => sys_getpgrp(),
        Sysno::setpgid => sys_setpgid(uctx.arg0() as i32, uctx.arg1() as i32),

        // signal
        Sysno::rt_sigprocmask => sys_rt_sigprocmask(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::rt_sigaction => sys_rt_sigaction(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::rt_sigpending => sys_rt_sigpending(uctx.arg0().into(), uctx.arg1() as _),
        Sysno::rt_sigreturn => sys_rt_sigreturn(uctx),
        Sysno::rt_sigtimedwait => sys_rt_sigtimedwait(
            uctx,
            uctx.arg0().into(),
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::rt_sigsuspend => sys_rt_sigsuspend(uctx, uctx.arg0().into(), uctx.arg1() as _),
        Sysno::kill => sys_kill(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::tkill => sys_tkill(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::tgkill => sys_tgkill(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::rt_sigqueueinfo => sys_rt_sigqueueinfo(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::rt_tgsigqueueinfo => sys_rt_tgsigqueueinfo(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),
        Sysno::sigaltstack => sys_sigaltstack(uctx, uctx.arg0().into(), uctx.arg1().into()),
        Sysno::futex => sys_futex(
            uctx.arg0().into(),
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4().into(),
            uctx.arg5() as _,
        ),
        Sysno::get_robust_list => {
            sys_get_robust_list(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2().into())
        }
        Sysno::set_robust_list => sys_set_robust_list(uctx.arg0().into(), uctx.arg1() as _),

        // sys
        Sysno::getuid => sys_getuid(),
        Sysno::geteuid => sys_geteuid(),
        Sysno::getgid => sys_getgid(),
        Sysno::getegid => sys_getegid(),
        Sysno::setuid => sys_setuid(uctx.arg0() as _),
        Sysno::setgid => sys_setgid(uctx.arg0() as _),
        Sysno::getresuid => {
            sys_getresuid(uctx.arg0().into(), uctx.arg1().into(), uctx.arg2().into())
        }
        Sysno::getresgid => {
            sys_getresgid(uctx.arg0().into(), uctx.arg1().into(), uctx.arg2().into())
        }
        Sysno::setfsuid => sys_setfsuid(uctx.arg0() as _),
        Sysno::setfsgid => sys_setfsgid(uctx.arg0() as _),
        Sysno::getgroups => sys_getgroups(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::setgroups => sys_setgroups(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::uname => sys_uname(uctx.arg0().into()),
        Sysno::sethostname => sys_sethostname(uctx.arg0().into(), uctx.arg1() as _),
        Sysno::reboot => sys_reboot(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
        ),
        Sysno::sysinfo => sys_sysinfo(uctx.arg0().into()),
        Sysno::syslog => sys_syslog(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::getrandom => sys_getrandom(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::seccomp => sys_seccomp(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        #[cfg(target_arch = "riscv64")]
        Sysno::riscv_flush_icache => sys_riscv_flush_icache(uctx.arg2()),
        #[cfg(target_arch = "riscv64")]
        Sysno::riscv_hwprobe => sys_riscv_hwprobe(
            uctx.arg0().into(),
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),

        // sync
        Sysno::membarrier => sys_membarrier(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),

        // time
        #[cfg(target_arch = "x86_64")]
        Sysno::time => sys_time(uctx.arg0().into()),
        Sysno::gettimeofday => sys_gettimeofday(uctx.arg0().into()),
        Sysno::settimeofday => sys_settimeofday(uctx.arg0().into(), uctx.arg1().into()),
        Sysno::times => sys_times(uctx.arg0().into()),
        Sysno::clock_gettime => sys_clock_gettime(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::clock_settime => sys_clock_settime(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::clock_getres => sys_clock_getres(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::getitimer => sys_getitimer(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::setitimer => sys_setitimer(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2().into()),

        // msg
        Sysno::msgget => sys_msgget(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::msgsnd => sys_msgsnd(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::msgrcv => sys_msgrcv(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4() as _,
        ),
        Sysno::msgctl => sys_msgctl(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2().into()),

        // shm
        Sysno::shmget => sys_shmget(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::shmat => sys_shmat(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::shmctl => sys_shmctl(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2().into()),
        Sysno::shmdt => sys_shmdt(uctx.arg0() as _),

        // net
        Sysno::socket => sys_socket(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        Sysno::socketpair => sys_socketpair(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
        ),
        Sysno::bind => sys_bind(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::connect => sys_connect(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::getsockname => {
            sys_getsockname(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2().into())
        }
        Sysno::getpeername => {
            sys_getpeername(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2().into())
        }
        Sysno::listen => sys_listen(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::accept => sys_accept(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2().into()),
        Sysno::accept4 => sys_accept4(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2().into(),
            uctx.arg3() as _,
        ),
        Sysno::shutdown => sys_shutdown(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::sendto => sys_sendto(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4().into(),
            uctx.arg5() as _,
        ),
        Sysno::recvfrom => sys_recvfrom(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4().into(),
            uctx.arg5().into(),
        ),
        Sysno::sendmsg => sys_sendmsg(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::recvmsg => sys_recvmsg(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _),
        Sysno::getsockopt => sys_getsockopt(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4().into(),
        ),
        Sysno::setsockopt => sys_setsockopt(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2() as _,
            uctx.arg3().into(),
            uctx.arg4() as _,
        ),
        Sysno::sendmmsg => sys_sendmmsg(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
        ),
        Sysno::recvmmsg => sys_recvmmsg(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2() as _,
            uctx.arg3() as _,
            uctx.arg4().into(),
        ),

        // signal file descriptors
        Sysno::signalfd4 => sys_signalfd4(
            uctx.arg0() as _,
            uctx.arg1().into(),
            uctx.arg2(),
            uctx.arg3() as _,
        ),

        // timer file descriptors
        Sysno::timerfd_create => sys_timerfd_create(uctx.arg0() as _, uctx.arg1() as _),
        Sysno::timerfd_settime => sys_timerfd_settime(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3().into(),
        ),
        Sysno::timerfd_gettime => sys_timerfd_gettime(uctx.arg0() as _, uctx.arg1().into()),

        #[cfg(feature = "ebpf")]
        Sysno::bpf => posix_bpf::sys_bpf(uctx.arg0() as _, uctx.arg1() as _, uctx.arg2() as _),
        #[cfg(not(feature = "ebpf"))]
        Sysno::bpf => sys_dummy_fd(sysno),

        Sysno::inotify_init1 => sys_inotify_init1(uctx.arg0() as _),
        Sysno::inotify_add_watch => {
            sys_inotify_add_watch(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2() as _)
        }
        Sysno::inotify_rm_watch => sys_inotify_rm_watch(uctx.arg0() as _, uctx.arg1() as _),

        // dummy fds
        Sysno::fanotify_init
        | Sysno::userfaultfd
        | Sysno::perf_event_open
        | Sysno::io_uring_setup
        | Sysno::fsopen
        | Sysno::fspick
        | Sysno::open_tree
        | Sysno::memfd_secret => sys_dummy_fd(sysno),

        Sysno::timer_create => {
            sys_timer_create(uctx.arg0() as _, uctx.arg1().into(), uctx.arg2().into())
        }
        Sysno::timer_gettime => sys_timer_gettime(uctx.arg0() as _, uctx.arg1().into()),
        Sysno::timer_settime => sys_timer_settime(
            uctx.arg0() as _,
            uctx.arg1() as _,
            uctx.arg2().into(),
            uctx.arg3().into(),
        ),
        Sysno::timer_delete => sys_timer_delete(uctx.arg0() as _),
        Sysno::timer_getoverrun => sys_timer_getoverrun(uctx.arg0() as _),

        // sync_file_range: return success (no-op, same as fsync for directories)
        Sysno::sync_file_range => Ok(0),

        // Crashpad probes ptrace while handling a crash. Linux returns EPERM when
        // tracing is unavailable to the caller; returning ENOSYS makes Chromium
        // treat the runtime as missing a core process interface and obscures the
        // actual crash path. This kernel does not expose ptrace to user space, so
        // report the Linux permission result without pretending to trace.
        Sysno::ptrace => Err(kerrno::KError::OperationNotPermitted),

        // Known benign unimplemented syscalls (glibc handles ENOSYS gracefully)
        Sysno::rseq => {
            debug!("sys_rseq: not implemented, returning ENOSYS");
            Err(kerrno::KError::Unsupported)
        }

        // TEE syscalls (500-599)
        #[cfg(feature = "tee")]
        _ if (500..600).contains(&uctx.sysno()) => {
            match tee_kernel::tee::dispatch_irq_tee_syscall(sysno, uctx) {
                Ok(_) => Ok(tee_kernel::TEE_SUCCESS as isize),
                Err(errno) => Ok(errno as isize),
            }
        }

        // TIPC syscalls (>=600) return TIPC-specific error codes
        // (not Linux errno) so that rust-libtipc can map them correctly.
        #[cfg(feature = "tipc")]
        _ if uctx.sysno() >= 600 => match tipc::syscall::dispatch_irq_tipc_syscall(sysno, uctx) {
            Ok(ret) => Ok(ret),
            Err(err) => Ok(tipc::error::kerror_to_tipc_errno(err, sysno) as isize),
        },

        _ => {
            let tid = kprocess::current_user_tid();
            warn!("Unimplemented syscall: {sysno} (tid={tid})");
            Err(kerrno::KError::Unsupported)
        }
    };

    debug!("Syscall {sysno} return {result:?}");
    if let Err(ref err) = result {
        warn!("SANDBOX_SYSCALL_ERROR sysno={} err={:?}", sysno, err);
    }

    uctx.set_retval(result.unwrap_or_else(|err| -LinuxError::from(err).into_raw() as _) as _);

    // rt_sigreturn restores the saved context from before the signal handler ran.
    // If we allow the normal post-syscall signal check to run, it may immediately
    // re-deliver the same signal whose handler just returned, causing an infinite
    // loop.  Returning from a signal handler is not a "normal" syscall return — the
    // restored context already represents where the thread was before the signal
    // arrived, so no additional signal processing is needed.  Skipping this check
    // matches Linux kernel behavior (see arch/*/kernel/signal.c: restore_sigcontext).
    if sysno == Sysno::rt_sigreturn && result.is_ok() {
        UserThreadRuntimeAction::SkipSignalCheckOnce
    } else {
        UserThreadRuntimeAction::Continue
    }
}
