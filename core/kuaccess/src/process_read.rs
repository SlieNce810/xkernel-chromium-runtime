// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! 有界、只读、不触发缺页的跨进程用户内存读取。

use alloc::sync::Arc;

use kaddr_layout::{USER_SPACE_BASE, USER_SPACE_SIZE};
use kerrno::KError;
use khal::paging::MappingFlags;
use kprocess::{Pid, Process, current_user_process, job_control::query_process};
use memaddr::{PAGE_SIZE_4K, VirtAddr};

pub const MAX_PROCESS_READ: usize = 256;

/// 读取失败的原因。调用方必须区分未映射、未驻留和真正错误，
/// 不能把失败当成全零内容。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessReadError {
    InvalidInput,
    Exited,
    MmChanged,
    Unmapped,
    NotPresent,
    PermissionDenied,
    Backend(KError),
}

fn resolve_process(pid: Pid) -> Result<Arc<Process>, ProcessReadError> {
    let current = current_user_process();
    if pid == current.pid() {
        return Ok(current);
    }
    query_process(pid).map_err(|_| ProcessReadError::Exited)
}

/// 读取目标进程当前页表中已经驻留的用户页。
///
/// - out must be 1..=MAX_PROCESS_READ bytes;
/// - 全程持有目标 mm 的锁和 LiveAddressSpace，不会主动 fault-in；
/// - out is unchanged on every error path;
/// - 只能在可睡眠的任务上下文调用，不能在 IRQ 或 spinlock 临界区调用。
pub fn read_process_memory(
    pid: Pid,
    expected_mm_id: u64,
    start: usize,
    out: &mut [u8],
) -> Result<(), ProcessReadError> {
    if out.is_empty() || out.len() > MAX_PROCESS_READ {
        return Err(ProcessReadError::InvalidInput);
    }
    let end = start
        .checked_add(out.len())
        .ok_or(ProcessReadError::InvalidInput)?;
    let space_end = USER_SPACE_BASE + USER_SPACE_SIZE;
    if start < USER_SPACE_BASE || end > space_end {
        return Err(ProcessReadError::InvalidInput);
    }

    // 先取到活着的 mm 能力，再在锁内核对 mm_id，专门挡住 PID 复用。
    let process = resolve_process(pid)?;
    let live = process
        .address_space()
        .map_err(|_| ProcessReadError::Exited)?;
    let mm = live.lock();
    if mm.mm_id() != expected_mm_id {
        return Err(ProcessReadError::MmChanged);
    }

    // 先检查每个页的 VMA 和 READ 权限，再调用 MmSpace::read。
    // MmSpace::read 只接受 present PTE，不会进入 handle_page_fault。
    let mut staging = [0u8; MAX_PROCESS_READ];
    let mut offset = 0usize;
    while offset < out.len() {
        let address = start + offset;
        let page_left = PAGE_SIZE_4K - address % PAGE_SIZE_4K;
        let chunk = (out.len() - offset).min(page_left);
        let Some(vma) = mm.find_vma(VirtAddr::from_usize(address)) else {
            return Err(ProcessReadError::Unmapped);
        };
        if !vma
            .flags()
            .contains(MappingFlags::USER | MappingFlags::READ)
        {
            return Err(ProcessReadError::PermissionDenied);
        }
        match mm.read(
            VirtAddr::from_usize(address),
            &mut staging[offset..offset + chunk],
        ) {
            Ok(()) => {}
            Err(KError::BadAddress) => return Err(ProcessReadError::NotPresent),
            Err(error) => return Err(ProcessReadError::Backend(error)),
        }
        offset += chunk;
    }

    out.copy_from_slice(&staging[..out.len()]);
    Ok(())
}
