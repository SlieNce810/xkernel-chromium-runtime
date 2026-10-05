// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! POSIX syscall adapters for inotify instances and inode watches.

use core::ffi::c_char;

use kerrno::{KError, KResult};
use kfd_objects::inotify::{
    IN_ALL_EVENTS, IN_DONT_FOLLOW, IN_EXCL_UNLINK, IN_IGNORED, IN_ISDIR, IN_MASK_ADD,
    IN_MASK_CREATE, IN_ONESHOT, IN_ONLYDIR, IN_Q_OVERFLOW, IN_UNMOUNT, InotifyFd,
};
use kprocess::current_user_process;
use kvfs::NodeType;
use linux_raw_sys::general::{AT_FDCWD, AT_SYMLINK_NOFOLLOW, O_CLOEXEC, O_NONBLOCK, O_RDONLY};
use posix_types::UserConstPtr;

use crate::path::resolve_at;

const INIT_FLAGS: u32 = O_CLOEXEC | O_NONBLOCK;
const WATCH_FLAGS: u32 = IN_ONLYDIR
    | IN_DONT_FOLLOW
    | IN_EXCL_UNLINK
    | IN_MASK_CREATE
    | IN_MASK_ADD
    | IN_ONESHOT;
const VALID_WATCH_MASK: u32 = IN_ALL_EVENTS
    | IN_UNMOUNT
    | IN_Q_OVERFLOW
    | IN_IGNORED
    | IN_ISDIR
    | WATCH_FLAGS;

/// Creates a new inotify instance.
pub fn sys_inotify_init1(flags: u32) -> KResult<isize> {
    if flags & !INIT_FLAGS != 0 {
        return Err(KError::InvalidInput);
    }
    let file = InotifyFd::new_file(
        O_RDONLY | flags,
        kprocess::current_cred(),
    )?;
    current_user_process()
        .resources()?
        .add_file(file, flags & O_CLOEXEC != 0)
        .map(|fd| fd as isize)
}

/// Adds or updates an inode watch for an inotify instance.
pub fn sys_inotify_add_watch(
    fd: i32,
    pathname: UserConstPtr<c_char>,
    mask: u32,
) -> KResult<isize> {
    if mask & !VALID_WATCH_MASK != 0 {
        return Err(KError::InvalidInput);
    }
    let pathname = pathname.load_string()?;
    let path_flags = if mask & IN_DONT_FOLLOW != 0 {
        AT_SYMLINK_NOFOLLOW
    } else {
        0
    };
    let path = resolve_at(AT_FDCWD, Some(&pathname), path_flags)?.into_path()?;
    let inode = path.inode();
    if mask & IN_ONLYDIR != 0 && inode.node_type() != NodeType::Directory {
        return Err(KError::NotADirectory);
    }

    let file = current_user_process().resources()?.get_file(fd)?;
    InotifyFd::from_file(&file)?.add_watch(inode, mask).map(|wd| wd as isize)
}

/// Removes an existing watch from an inotify instance.
pub fn sys_inotify_rm_watch(fd: i32, wd: i32) -> KResult<isize> {
    let file = current_user_process().resources()?.get_file(fd)?;
    InotifyFd::from_file(&file)?.remove_watch(wd)?;
    Ok(0)
}
