// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

use kaddr_layout::{USER_HEAP_BASE, USER_SPACE_BASE, USER_SPACE_SIZE};
use khal::paging::{MappingFlags, PageSize};
use kprocess::current_user_process;
use memaddr::{PAGE_SIZE_4K, VirtAddr};
use memspace::VmRuntimeRef;
use osvm::write_vm_bytes;
use unittest::def_test;
use unittest_support::TestUserBuffer;

use crate::process_read::{MAX_PROCESS_READ, ProcessReadError, read_process_memory};

fn current_ids() -> (kprocess::Pid, u64) {
    let process = current_user_process();
    (process.pid(), process.mm_id().unwrap())
}

#[def_test(user)]
fn reads_known_bytes_across_page_boundary() {
    let buffer = TestUserBuffer::new(PAGE_SIZE_4K + 16).unwrap();
    let mut expected = [0u8; 16];
    for (index, byte) in expected.iter_mut().enumerate() {
        *byte = index as u8 + 1;
    }
    let start = buffer.as_user_ptr::<u8>() as usize + PAGE_SIZE_4K - 8;
    write_vm_bytes(start as *mut u8, &expected).unwrap();
    let (pid, mm_id) = current_ids();
    let mut out = [0u8; 16];
    read_process_memory(pid, mm_id, start, &mut out).unwrap();
    assert_eq!(out, expected);
}

#[def_test(user)]
fn rejects_wrong_mm_id_without_touching_output() {
    let buffer = TestUserBuffer::new(16).unwrap();
    buffer.write_bytes(&[1, 2, 3, 4]).unwrap();
    let (pid, mm_id) = current_ids();
    let mut out = [0xCCu8; 4];
    let result = read_process_memory(
        pid,
        mm_id.wrapping_add(1),
        buffer.as_user_ptr::<u8>() as usize,
        &mut out,
    );
    assert!(matches!(result, Err(ProcessReadError::MmChanged)));
    assert_eq!(out, [0xCC; 4]);
}

#[def_test(user)]
fn rejects_invalid_lengths_and_unmapped_ranges() {
    let (pid, mm_id) = current_ids();
    let mut empty = [];
    assert!(matches!(
        read_process_memory(pid, mm_id, USER_SPACE_BASE, &mut empty),
        Err(ProcessReadError::InvalidInput)
    ));
    let mut too_large = [0u8; MAX_PROCESS_READ + 1];
    assert!(matches!(
        read_process_memory(pid, mm_id, USER_SPACE_BASE, &mut too_large),
        Err(ProcessReadError::InvalidInput)
    ));
    let mut out = [0xCCu8; 8];
    let result = read_process_memory(
        pid,
        mm_id,
        USER_SPACE_BASE + USER_SPACE_SIZE - PAGE_SIZE_4K,
        &mut out,
    );
    assert!(matches!(result, Err(ProcessReadError::Unmapped)));
    assert_eq!(out, [0xCC; 8]);
}

#[def_test(user)]
fn reports_not_present_without_faulting_in() {
    let process = current_user_process();
    let start = VirtAddr::from_usize(USER_HEAP_BASE + 0x1000_0000);
    let live = process.address_space().unwrap();
    live.lock()
        .map(
            start,
            PAGE_SIZE_4K,
            MappingFlags::USER | MappingFlags::READ | MappingFlags::WRITE,
            false,
            VmRuntimeRef::new_anon_private(start, PageSize::Size4K),
        )
        .unwrap();
    let (pid, mm_id) = current_ids();
    let mut out = [0xCCu8; 8];
    let result = read_process_memory(pid, mm_id, start.as_usize(), &mut out);
    let present_after = live.lock().find_vma(start).is_some();
    live.lock().unmap(start, PAGE_SIZE_4K).unwrap();
    assert!(present_after);
    assert!(matches!(result, Err(ProcessReadError::NotPresent)));
    assert_eq!(out, [0xCC; 8]);
}

#[def_test(user)]
fn rejects_vma_without_read_permission() {
    let process = current_user_process();
    let start = VirtAddr::from_usize(USER_HEAP_BASE + 0x1000_1000);
    let live = process.address_space().unwrap();
    live.lock()
        .map(
            start,
            PAGE_SIZE_4K,
            MappingFlags::USER | MappingFlags::READ | MappingFlags::WRITE,
            false,
            VmRuntimeRef::new_anon_private(start, PageSize::Size4K),
        )
        .unwrap();
    live.lock()
        .protect(
            start,
            PAGE_SIZE_4K,
            MappingFlags::USER | MappingFlags::WRITE,
        )
        .unwrap();
    let (pid, mm_id) = current_ids();
    let mut out = [0xCCu8; 8];
    let result = read_process_memory(pid, mm_id, start.as_usize(), &mut out);
    live.lock().unmap(start, PAGE_SIZE_4K).unwrap();
    assert!(matches!(result, Err(ProcessReadError::PermissionDenied)));
    assert_eq!(out, [0xCC; 8]);
}
