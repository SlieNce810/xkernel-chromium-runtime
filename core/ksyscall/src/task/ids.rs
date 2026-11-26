// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Process identity syscalls.

use kerrno::{KError, KResult};

/// Returns the process ID of the current process.
pub fn sys_getpid() -> KResult<isize> {
    let current_thread = kprocess::current_user_thread();
    let namespace = current_thread
        .pid_namespace()
        .ok_or(KError::NoSuchProcess)?;
    current_thread
        .process()
        .pid_in_namespace(&namespace)
        .map(|pid| pid as isize)
        .ok_or(KError::NoSuchProcess)
}

/// Returns the parent process ID of the current process.
pub fn sys_getppid() -> KResult<isize> {
    let current_thread = kprocess::current_user_thread();
    let namespace = current_thread
        .pid_namespace()
        .ok_or(KError::NoSuchProcess)?;
    let parent_pid = current_thread
        .process()
        .parent()
        .and_then(|parent| parent.pid_in_namespace(&namespace))
        .unwrap_or(0);
    Ok(parent_pid as isize)
}
