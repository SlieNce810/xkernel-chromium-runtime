// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Process and thread exit syscalls.
//!
//! This module implements process and thread termination operations including:
//! - Process exit (exit, exit_group, etc.)
//! - Exit code handling
//! - Process cleanup and resource release

use kerrno::KResult;
use posix_process::do_exit;

use kprocess::current_user_process;

pub fn sys_exit(exit_code: i32) -> KResult<isize> {
    warn!("SANDBOX_SYS_EXIT pid={} code={} group=0", current_user_process().pid(), exit_code);
    do_exit(exit_code << 8, false);
    Ok(0)
}

pub fn sys_exit_group(exit_code: i32) -> KResult<isize> {
    warn!("SANDBOX_SYS_EXIT pid={} code={} group=1", current_user_process().pid(), exit_code);
    do_exit(exit_code << 8, true);
    Ok(0)
}
