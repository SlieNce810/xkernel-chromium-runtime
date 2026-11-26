// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Epoll syscalls.

use alloc::vec;
use core::sync::atomic::{AtomicUsize, Ordering};

use bitflags::bitflags;
use kerrno::{KError, KResult};
use kfd_objects::epoll::{Epoll, EpollEvent, EpollFlags};
use kpoll::IoEvents;
use ktask::future::{self, block_on, poll_io};
use ktime_types::TimeSpan;
use linux_raw_sys::general::{
    EPOLL_CLOEXEC, EPOLL_CTL_ADD, EPOLL_CTL_DEL, EPOLL_CTL_MOD, epoll_event, timespec,
};
use posix_types::{TimeSpanLike, UserConstPtr, UserPtr, k_sigset};

static CHROMIUM_EPOLL_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);
const CHROMIUM_EPOLL_TRACE_LIMIT: usize = 4096;

fn trace_chromium_epoll(op: &str, epfd: i32, fd: i32, events: u32, result: &KResult<isize>) {
    let process = kprocess::current_user_process();
    let Ok(argv) = process.cmdline() else { return };
    if !argv.iter().any(|arg| arg.contains("/chromium")) {
        return;
    }
    let seq = CHROMIUM_EPOLL_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    if seq >= CHROMIUM_EPOLL_TRACE_LIMIT {
        return;
    }
    warn!(
        "CHROMIUM_EPOLL seq={} op={} pid={} epfd={} fd={} events={:#x} result={:?}",
        seq,
        op,
        process.pid(),
        epfd,
        fd,
        events,
        result
    );
}

fn trace_chromium_epoll_wait(epfd: i32, ready: usize, output: &[epoll_event]) {
    let process = kprocess::current_user_process();
    let Ok(argv) = process.cmdline() else { return };
    if !argv.iter().any(|arg| arg.contains("/chromium")) {
        return;
    }
    let seq = CHROMIUM_EPOLL_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    if seq >= CHROMIUM_EPOLL_TRACE_LIMIT {
        return;
    }
    let rows = output
        .iter()
        .take(8)
        .map(|event| (event.events, event.data))
        .collect::<alloc::vec::Vec<_>>();
    warn!(
        "CHROMIUM_EPOLL_WAIT seq={} pid={} epfd={} ready={} rows={:?}",
        seq, process.pid(), epfd, ready, rows
    );
}

bitflags! {
    // Flags for the `epoll_create1` syscall.
    #[derive(Debug, Clone, Copy, Default)]
    pub struct EpollCreateFlags: u32 {
        const CLOEXEC = EPOLL_CLOEXEC;
    }
}

/// Creates an epoll instance.
pub fn sys_epoll_create1(flags: u32) -> KResult<isize> {
    let flags = EpollCreateFlags::from_bits(flags).ok_or(KError::InvalidInput)?;
    debug!("sys_epoll_create1 <= flags: {flags:?}");

    kprocess::current_resources()
        .add_file(
            Epoll::new_file(kprocess::current_cred())?,
            flags.contains(EpollCreateFlags::CLOEXEC),
        )
        .map(|fd| fd as isize)
}

/// Adds, modifies, or removes an epoll interest.
pub fn sys_epoll_ctl(
    epfd: i32,
    op: u32,
    fd: i32,
    event: UserConstPtr<epoll_event>,
) -> KResult<isize> {
    let epoll_file = kprocess::current_resources().get_file(epfd)?;
    let epoll = Epoll::from_file(&epoll_file)?;
    let file = kprocess::current_resources().get_file(fd)?;
    debug!("sys_epoll_ctl <= epfd: {epfd}, op: {op}, fd: {fd}");

    let parse_event = || -> KResult<(EpollEvent, EpollFlags)> {
        let event = event.read_vm()?;
        let events = IoEvents::from_bits_truncate(event.events);
        let flags =
            EpollFlags::from_bits(event.events & !events.bits()).ok_or(KError::InvalidInput)?;
        Ok((
            EpollEvent {
                events,
                user_data: event.data,
            },
            flags,
        ))
    };

    let result = match op {
        EPOLL_CTL_ADD => {
            let (event, flags) = parse_event()?;
            epoll.add(fd, file.clone(), event, flags)?;
            Ok(0)
        }
        EPOLL_CTL_MOD => {
            let (event, flags) = parse_event()?;
            epoll.modify(fd, file.clone(), event, flags)?;
            Ok(0)
        }
        EPOLL_CTL_DEL => {
            epoll.delete(fd, file)?;
            Ok(0)
        }
        _ => Err(KError::InvalidInput),
    };
    let events = event.read_vm().map(|value| value.events).unwrap_or(0);
    trace_chromium_epoll("ctl", epfd, fd, events, &result);
    result
}

fn do_epoll_wait(
    epfd: i32,
    events: UserPtr<epoll_event>,
    maxevents: i32,
    timeout: Option<TimeSpan>,
    sigmask: UserConstPtr<k_sigset>,
    sigsetsize: usize,
) -> KResult<isize> {
    posix_types::check_sigset_size(sigsetsize)?;
    debug!("sys_epoll_wait <= epfd: {epfd}, maxevents: {maxevents}, timeout: {timeout:?}");

    if maxevents <= 0 {
        return Err(KError::InvalidInput);
    }

    let epoll_file = kprocess::current_resources().get_file(epfd)?;
    let epoll = Epoll::from_file(&epoll_file)?;
    // `posix-types::UserPtr` models copy-to-user semantics rather than a borrowed
    // mutable user slice, so we stage ready events in kernel memory and copy them
    // back once polling completes.
    let mut output = vec![epoll_event { events: 0, data: 0 }; maxevents as usize];
    let sigmask = sigmask
        .check_non_null()
        .map(UserConstPtr::read_vm)
        .transpose()?;

    let ready =
        kprocess::current_user_thread().with_temp_blocked(sigmask.map(Into::into), || {
            match block_on(future::timeout(
                timeout,
                poll_io(epoll.as_ref(), IoEvents::IN, false, || {
                    epoll.poll_events(&mut output)
                }),
            )) {
                Ok(r) => r,
                Err(_) => Ok(0),
            }
        })?;

    trace_chromium_epoll_wait(epfd, ready, &output);
    events.write_vm_slice(&output[..ready])?;
    Ok(ready as isize)
}

/// Waits for epoll events with a millisecond timeout.
pub fn sys_epoll_pwait(
    epfd: i32,
    events: UserPtr<epoll_event>,
    maxevents: i32,
    timeout: i32,
    sigmask: UserConstPtr<k_sigset>,
    sigsetsize: usize,
) -> KResult<isize> {
    let timeout = match timeout {
        -1 => None,
        t if t >= 0 => Some(TimeSpan::from_millis(t as u64)),
        _ => return Err(KError::InvalidInput),
    };
    do_epoll_wait(epfd, events, maxevents, timeout, sigmask, sigsetsize)
}

/// Waits for epoll events with a high-precision timeout.
pub fn sys_epoll_pwait2(
    epfd: i32,
    events: UserPtr<epoll_event>,
    maxevents: i32,
    timeout: UserConstPtr<timespec>,
    sigmask: UserConstPtr<k_sigset>,
    sigsetsize: usize,
) -> KResult<isize> {
    let timeout = timeout
        .check_non_null()
        .map(UserConstPtr::read_vm)
        .transpose()?
        .map(|timeout| timeout.try_into_time_span())
        .transpose()?;
    do_epoll_wait(epfd, events, maxevents, timeout, sigmask, sigsetsize)
}
