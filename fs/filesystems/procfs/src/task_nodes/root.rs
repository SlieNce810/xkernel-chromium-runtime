// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

use alloc::{
    borrow::Cow,
    boxed::Box,
    collections::BTreeMap,
    format,
    string::{String, ToString},
    sync::{Arc, Weak},
    vec,
    vec::Vec,
};
use core::{
    ffi::CStr,
    iter, str,
    sync::atomic::{AtomicUsize, Ordering},
};

use kaddr_layout::{SIGNAL_TRAMPOLINE, USER_HEAP_BASE, USER_STACK_SIZE, USER_STACK_TOP};
use khal::paging::MappingFlags;
use kprocess::{AsThread, LiveAddressSpace, Process, TaskStat, procfs};
use ktask::{KtaskRef, TaskState, WeakKtaskRef, current};
#[cfg(feature = "tee")]
use kvfs::DirMapping;
use kvfs::{
    CommandFile, Dentry, FileOperations, InodeOperations, InodeSymlinkOperations, LookupFlags,
    LookupIntent, MagicLinkOps, Metadata, MetadataUpdate, NodeFlags, NodePermission, NodeType,
    ResolvedObject, SeqFileInode, SeqIterator, SimpleDir, SimpleDirLookup, SimpleDirOps,
    SimpleFile, SimpleFileOperation, SimpleFs, SimpleFsNode, VfsError, VfsFile, VfsInode,
    VfsResult,
};
use memspace::MmMemoryUsage;

#[cfg(feature = "tee")]
use super::tee;
use crate::task_nodes::mounts::ProcMountIter;

/// Upgrades a weak task reference held by a procfs file closure.
///
/// Returns [`VfsError::NoSuchProcess`] (ESRCH) once the task has exited and
/// been reclaimed, matching Linux `get_proc_task()` failure semantics for
/// reads/writes on an already-open `/proc/<pid>/...` file. Lookup-time paths
/// that materialize dentries instead keep returning `NotFound` (ENOENT).
pub(super) fn upgrade_task(task_weak: &WeakKtaskRef) -> VfsResult<KtaskRef> {
    task_weak.upgrade().ok_or(VfsError::NoSuchProcess)
}

struct ProcessTaskDir {
    fs: Arc<SimpleFs>,
    process: Weak<Process>,
}

impl SimpleDirOps for ProcessTaskDir {
    fn child_names<'a>(&'a self) -> VfsResult<Box<dyn Iterator<Item = Cow<'a, str>> + 'a>> {
        let Some(process) = self.process.upgrade() else {
            return Ok(Box::new(iter::empty()));
        };
        Ok(Box::new(
            process
                .threads()
                .into_iter()
                .map(|tid| tid.to_string().into()),
        ))
    }

    fn lookup_child(&self, lookup: SimpleDirLookup<'_>, name: &str) -> VfsResult<Dentry> {
        let process = self.process.upgrade().ok_or(VfsError::NotFound)?;
        let tid = name.parse::<u32>().map_err(|_| VfsError::NotFound)?;
        let task = procfs::thread_task(tid).map_err(|_| VfsError::NotFound)?;
        if task.as_thread().process().pid() != process.pid() {
            return Err(VfsError::NotFound);
        }

        Ok(make_thread_dir(lookup, name, self.fs.clone(), &task))
    }

    fn supports_dentry_cache(&self) -> bool {
        false
    }

    fn link_count(&self) -> u64 {
        self.process
            .upgrade()
            .map(|process| 2 + process.threads().len() as u64)
            .unwrap_or(2)
    }
}

/// 读取目标任务的 MM 快照；内核线程或已退出的任务返回 `None`。
///
/// 这里是 procfs 唯一接触 MM 锁的地方：拿到 `Copy` 快照后立刻释放，
/// 之后的字符串格式化全部在锁外完成。
fn task_memory_usage(task: &KtaskRef) -> Option<MmMemoryUsage> {
    let thread = task.try_as_thread()?;
    let aspace = thread.process().address_space().ok()?;
    let usage = aspace.lock().memory_usage();
    Some(usage)
}

#[derive(Clone, Copy)]
struct SmapsRollupUsage {
    rss_kb: u64,
    pss_kb: u64,
    uss_kb: u64,
    shared_kb: u64,
}

/// Computes mapping-based RSS, proportional set size, and unique set size.
///
/// This is intentionally a cold-path procfs read. It snapshots the PFN list
/// for each live process one address space at a time, then divides each target
/// mapping by the number of live user mappings of the same frame. A failed
/// walk makes the whole result unavailable instead of undercounting PSS.
#[derive(Clone, Copy)]
struct ProcessSmapsRollupRow {
    pid: u32,
    ppid: u32,
    usage: SmapsRollupUsage,
}

/// Builds one all-process mapcount snapshot. The per-PID smaps_rollup path
/// needs one target row; the Chromium benchmark uses the process-tree file to
/// avoid rescanning every address space once for each PID in the same sample.
fn process_smaps_rollup_snapshot() -> Option<Vec<ProcessSmapsRollupRow>> {
    let mut process_frames = Vec::<(u32, u32, Vec<usize>)>::new();
    for process in kprocess::scheduler::processes() {
        let Ok(aspace) = process.address_space() else {
            continue;
        };
        let frames = aspace.lock().resident_page_frames()?;
        let ppid = process.parent().map_or(0, |parent| parent.pid());
        process_frames.push((process.pid(), ppid, frames));
    }

    // On the 2 GiB competition guest, PFNs fit in a compact dense index. Avoid
    // allocating a BTreeMap node and doing tree searches for every resident
    // mapping on the 1 Hz sampler hot path. Keep the sparse fallback for large
    // physical address spaces so the procfs endpoint remains bounded.
    const MAX_DENSE_PFN_SLOTS: usize = 4 * 1024 * 1024;
    let max_frame = process_frames
        .iter()
        .flat_map(|(_, _, frames)| frames.iter().copied())
        .max()?;
    let slot_count = max_frame.checked_add(1)?;
    let mut dense_map_counts = if slot_count <= MAX_DENSE_PFN_SLOTS {
        Some(vec![0u32; slot_count])
    } else {
        None
    };
    let mut sparse_map_counts = if dense_map_counts.is_none() {
        Some(BTreeMap::<usize, u32>::new())
    } else {
        None
    };
    for (_, _, frames) in &process_frames {
        for frame in frames {
            if let Some(counts) = dense_map_counts.as_mut() {
                let count = counts.get_mut(*frame)?;
                *count = count.checked_add(1)?;
            } else {
                let counts = sparse_map_counts.as_mut()?;
                let count = counts.entry(*frame).or_default();
                *count = count.checked_add(1)?;
            }
        }
    }

    let mut snapshot = Vec::with_capacity(process_frames.len());
    for (pid, ppid, frames) in process_frames {
        let mut pss_scaled_kb = 0u128;
        let mut unique_pages = 0u64;
        let mut shared_pages = 0u64;
        for frame in &frames {
            let map_count = if let Some(counts) = dense_map_counts.as_ref() {
                *counts.get(*frame)? as usize
            } else {
                *sparse_map_counts.as_ref()?.get(frame)? as usize
            };
            if map_count == 0 {
                return None;
            }
            pss_scaled_kb += 4096u128 / map_count as u128;
            if map_count == 1 {
                unique_pages += 1;
            } else {
                shared_pages += 1;
            }
        }
        snapshot.push(ProcessSmapsRollupRow {
            pid,
            ppid,
            usage: SmapsRollupUsage {
                rss_kb: (frames.len() as u64) * 4,
                pss_kb: ((pss_scaled_kb + 512) / 1024) as u64,
                uss_kb: unique_pages * 4,
                shared_kb: shared_pages * 4,
            },
        });
    }
    Some(snapshot)
}

fn task_smaps_rollup_usage(task: &KtaskRef) -> Option<SmapsRollupUsage> {
    let target_pid = task.try_as_thread()?.process().pid();
    process_smaps_rollup_snapshot()?
        .into_iter()
        .find(|row| row.pid == target_pid)
        .map(|row| row.usage)
}

fn process_descends_from(pid: u32, root_pid: u32, snapshot: &[ProcessSmapsRollupRow]) -> bool {
    let mut current = pid;
    for _ in 0..=snapshot.len() {
        if current == root_pid {
            return true;
        }
        let Some(row) = snapshot.iter().find(|row| row.pid == current) else {
            return false;
        };
        if row.ppid == 0 || row.ppid == current {
            return false;
        }
        current = row.ppid;
    }
    false
}

fn format_tree_smaps_rollup(task: &KtaskRef) -> Vec<u8> {
    let Some(target_pid) = task.try_as_thread().map(|thread| thread.process().pid()) else {
        return b"UNAVAILABLE\n".to_vec();
    };
    let Some(snapshot) = process_smaps_rollup_snapshot() else {
        return b"UNAVAILABLE\n".to_vec();
    };
    if !snapshot.iter().any(|row| row.pid == target_pid) {
        return b"UNAVAILABLE\n".to_vec();
    }
    let mut output = String::from("PID PPID RSS_KB PSS_KB USS_KB\n");
    for row in snapshot.iter().filter(|row| process_descends_from(row.pid, target_pid, &snapshot)) {
        output.push_str(&format!(
            "{} {} {} {} {}\n",
            row.pid, row.ppid, row.usage.rss_kb, row.usage.pss_kb, row.usage.uss_kb
        ));
    }
    output.into_bytes()
}
fn format_smaps_rollup(task: &KtaskRef) -> Vec<u8> {
    let Some(usage) = task_smaps_rollup_usage(task) else {
        return b"Rss: UNAVAILABLE\nPss: UNAVAILABLE\nUSS: UNAVAILABLE\nShared: UNAVAILABLE\n"
            .to_vec();
    };
    format!(
        "Rss:\t{} kB\nPss:\t{} kB\nUSS:\t{} kB\nShared:\t{} kB\n",
        usage.rss_kb, usage.pss_kb, usage.uss_kb, usage.shared_kb
    )
    .into_bytes()
}

/// `/proc/<pid>/statm`：七个基础页字段，顺序与 Linux 完全一致。
///
/// `size resident shared text lib data dt`
/// - `lib` 与 `dt` 在 Linux 上恒为 0：库页并入 text/data，脏页数不单独维护；
/// - `text` / `data` 是**显式近似的口径**（可执行 VMA / 私有可写 VMA）。
///   精确的 ELF `data_vm + stack_vm` 需要 exec 布局元数据，属于后续阶段，
///   已在设计文档的 Deferred Items 中登记。
fn format_statm(task: &KtaskRef) -> String {
    let Some(usage) = task_memory_usage(task) else {
        // Linux 对没有 mm 的任务也返回七个零，而不是报错。
        return String::from("0 0 0 0 0 0 0\n");
    };
    format!(
        "{} {} {} {} 0 {} 0\n",
        usage.virtual_pages,
        usage.resident_pages(),
        usage.shared_pages(),
        usage.text_pages,
        usage.data_pages
    )
}

/// Linux `/proc/<pid>/status` 的 State 列字符。
fn task_state_char(task: &KtaskRef) -> char {
    match task.state() {
        TaskState::Running | TaskState::Ready => 'R',
        TaskState::Blocked => 'S',
        TaskState::Exited => 'Z',
    }
}

fn task_status(task: &KtaskRef) -> String {
    let thread = task.as_thread();
    let namespace = thread.pid_namespace();
    let tgid = namespace
        .as_ref()
        .and_then(|ns| thread.process().pid_in_namespace(ns))
        .unwrap_or_else(|| thread.process().pid());
    let pid = namespace
        .as_ref()
        .and_then(|ns| thread.tid_in_namespace(ns))
        .unwrap_or_else(|| thread.tid());
    let credentials = thread.real_cred();
    let uids = (
        credentials.ruid(),
        credentials.euid(),
        credentials.suid(),
        credentials.fsuid(),
    );
    let gids = (
        credentials.rgid(),
        credentials.egid(),
        credentials.sgid(),
        credentials.fsgid(),
    );
    let groups = credentials
        .supplementary_groups()
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\t");
    format_task_status(
        &task.name(),
        tgid,
        pid as u64,
        task_state_char(task),
        thread.process().threads().len(),
        uids,
        gids,
        &groups,
        task_memory_usage(task),
    )
}

#[rustfmt::skip]
fn format_task_status(
    name: &str,
    tgid: u32,
    pid: u64,
    state: char,
    threads: usize,
    uids: (u32, u32, u32, u32),
    gids: (u32, u32, u32, u32),
    groups: &str,
    usage: Option<MmMemoryUsage>,
) -> String {
    // 单位：statm 用基础页，status 用 KiB，所以这里一律乘 4。
    let vm_size_kib = usage.map_or(0, |u| u.virtual_pages * 4);
    let vm_rss_kib = usage.map_or(0, |u| u.resident_pages() * 4);
    let vm_hwm_kib = usage.map_or(0, |u| u.peak_rss_pages * 4);
    format!(
        "Name:\t{}\n\
        Tgid:\t{}\n\
        Pid:\t{}\n\
        State:\t{}\n\
        Threads:\t{}\n\
        Uid:\t{} {} {} {}\n\
        Gid:\t{} {} {} {}\n\
        Groups:\t{}\n\
        Cpus_allowed:\t1\n\
        Cpus_allowed_list:\t0\n\
        Mems_allowed:\t1\n\
        Mems_allowed_list:\t0\n\
        VmSize:\t{} kB\n\
        VmRSS:\t{} kB\n\
        VmHWM:\t{} kB\n",
        name,
        tgid,
        pid,
        state,
        threads,
        uids.0,
        uids.1,
        uids.2,
        uids.3,
        gids.0,
        gids.1,
        gids.2,
        gids.3,
        groups,
        vm_size_kib,
        vm_rss_kib,
        vm_hwm_kib
    )
}

fn format_oom_score_adj(value: i32) -> Vec<u8> {
    format!("{value}\n").into_bytes()
}


fn parse_user_map_input(data: &[u8]) -> VfsResult<(u32, u32, u32)> {
    let text = str::from_utf8(data).map_err(|_| VfsError::InvalidInput)?;
    let mut fields = text.split_whitespace();
    let inside = fields.next().ok_or(VfsError::InvalidInput)?
        .parse::<u32>().map_err(|_| VfsError::InvalidInput)?;
    let outside = fields.next().ok_or(VfsError::InvalidInput)?
        .parse::<u32>().map_err(|_| VfsError::InvalidInput)?;
    let length = fields.next().ok_or(VfsError::InvalidInput)?
        .parse::<u32>().map_err(|_| VfsError::InvalidInput)?;
    if fields.next().is_some() || length == 0 {
        return Err(VfsError::InvalidInput);
    }
    Ok((inside, outside, length))
}

fn format_user_map(task: &KtaskRef, gid: bool) -> VfsResult<Vec<u8>> {
    let ns = task.as_thread().real_cred().user_namespace();
    let (inside, outside, length) = if gid { ns.gid_map_line() } else { ns.uid_map_line() };
    Ok(format!("{inside} {outside} {length}
").into_bytes())
}

fn user_map_file(fs: Arc<SimpleFs>, task_weak: WeakKtaskRef, gid: bool) -> Arc<SimpleFile> {
    SimpleFile::new_regular(
        fs,
        CommandFile::new(move |req| {
            let task = upgrade_task(&task_weak)?;
            let ns = task.as_thread().real_cred().user_namespace();
            match req {
                SimpleFileOperation::Read => Ok(Some(format_user_map(&task, gid)?)),
                SimpleFileOperation::Write { data, .. } => {
                    let (inside, outside, length) = parse_user_map_input(data)?;
                    let accepted = if gid {
                        ns.write_gid_map(inside, outside, length)
                    } else {
                        ns.write_uid_map(inside, outside, length)
                    };
                    if accepted { Ok(None) } else { Err(VfsError::PermissionDenied) }
                }
            }
        }),
    )
}

fn user_setgroups_file(fs: Arc<SimpleFs>, task_weak: WeakKtaskRef) -> Arc<SimpleFile> {
    SimpleFile::new_regular(
        fs,
        CommandFile::new(move |req| {
            let task = upgrade_task(&task_weak)?;
            let ns = task.as_thread().real_cred().user_namespace();
            match req {
                SimpleFileOperation::Read => Ok(Some(if ns.setgroups_denied() {
                    b"deny
".to_vec()
                } else {
                    b"allow
".to_vec()
                })),
                SimpleFileOperation::Write { data, .. } => {
                    if str::from_utf8(data).map(str::trim) == Ok("deny") {
                        ns.deny_setgroups();
                        Ok(None)
                    } else {
                        Err(VfsError::InvalidInput)
                    }
                }
            }
        }),
    )
}

/// Linux `OOM_SCORE_ADJ_MIN` / `OOM_SCORE_ADJ_MAX`; writes outside this range
/// are rejected with `-EINVAL` (fs/proc/base.c `oom_score_adj_write()`).
const OOM_SCORE_ADJ_MIN: i32 = -1000;
const OOM_SCORE_ADJ_MAX: i32 = 1000;

fn parse_oom_score_adj_input(data: &[u8]) -> VfsResult<Option<i32>> {
    if data.is_empty() {
        return Ok(None);
    }

    str::from_utf8(data)
        .ok()
        .map(str::trim)
        .and_then(|it| it.parse::<i32>().ok())
        .map(Some)
        .ok_or(VfsError::InvalidInput)
}

fn proc_self_target() -> VfsResult<String> {
    let task = current();
    let thread = task.try_as_thread().ok_or(VfsError::NotFound)?;
    Ok(thread.process().pid().to_string())
}

fn maps_permissions(flags: MappingFlags) -> [u8; 4] {
    [
        if flags.contains(MappingFlags::READ) {
            b'r'
        } else {
            b'-'
        },
        if flags.contains(MappingFlags::WRITE) {
            b'w'
        } else {
            b'-'
        },
        if flags.contains(MappingFlags::EXECUTE) {
            b'x'
        } else {
            b'-'
        },
        if flags.contains(MappingFlags::SHARED) {
            b's'
        } else {
            b'p'
        },
    ]
}

fn special_mapping_name(start: usize, end: usize, heap_top: usize) -> Option<&'static str> {
    let heap_start = USER_HEAP_BASE;
    if start < heap_top && end > heap_start {
        return Some("[heap]");
    }

    let stack_start = USER_STACK_TOP - USER_STACK_SIZE;
    if start < USER_STACK_TOP && end > stack_start {
        return Some("[stack]");
    }

    if start <= SIGNAL_TRAMPOLINE && end > SIGNAL_TRAMPOLINE {
        return Some("[sigtramp]");
    }

    None
}

#[derive(Clone)]
struct MapsEntry {
    start: usize,
    end: usize,
    flags: MappingFlags,
    offset: u64,
    inode: u64,
    path: Option<String>,
    name: Option<&'static str>,
}

fn backend_file_mapping(vma: &memspace::VmArea) -> Option<(u64, u64, Option<String>)> {
    let info = vma.file_mapping()?;
    Some((
        vma.file_offset_for(vma.start())?,
        info.inode,
        info.path.clone(),
    ))
}

const PROC_MAPS_ADDR_WIDTH: usize = 12;
const PROC_MAPS_PATH_COLUMN: usize = 73;

fn render_maps_line(item: &MapsEntry) -> String {
    let perms = maps_permissions(item.flags);
    let mut line = format!(
        "{:0width$x}-{:0width$x} {} {:08x} 00:00 {}",
        item.start,
        item.end,
        core::str::from_utf8(&perms).unwrap(),
        item.offset,
        item.inode,
        width = PROC_MAPS_ADDR_WIDTH,
    );

    if let Some(name) = item.name {
        if line.len() < PROC_MAPS_PATH_COLUMN {
            for _ in line.len()..PROC_MAPS_PATH_COLUMN {
                line.push(' ');
            }
        } else {
            line.push(' ');
        }
        line.push_str(name);
    } else if let Some(path) = item.path.as_deref() {
        if line.len() < PROC_MAPS_PATH_COLUMN {
            for _ in line.len()..PROC_MAPS_PATH_COLUMN {
                line.push(' ');
            }
        } else {
            line.push(' ');
        }
        line.push_str(path);
    }

    line.push('\n');
    line
}

struct MapsIter {
    aspace: LiveAddressSpace,
    heap_top: Arc<AtomicUsize>,
    entries: Vec<MapsEntry>,
    next_index: usize,
}

impl MapsIter {
    /// Holds the process mm alive, mirroring Linux `proc_maps_open()`
    /// `get_task_mm()`: the file keeps working after the process exits, and
    /// reads re-walk the current VMA list under the mm lock, so a live
    /// process's new mmap/munmap operations show up on the next read.
    ///
    /// Fails with `NoSuchProcess` when the runtime is already detached (the
    /// process is gone even though the task may not be reclaimed yet).
    fn new(task: &KtaskRef) -> VfsResult<Self> {
        let process = task.as_thread().process();
        Ok(Self {
            aspace: process.address_space()?,
            heap_top: process.heap_top_handle()?,
            entries: Vec::new(),
            next_index: 0,
        })
    }
}

impl SeqIterator for MapsIter {
    type Item = MapsEntry;

    fn rewind(&mut self) {
        self.entries.clear();
        self.next_index = 0;
        let aspace = self.aspace.lock();
        for vma in aspace.vmas() {
            let start = vma.start().as_usize();
            let end = vma.end().as_usize();
            let (offset, inode, path) = backend_file_mapping(vma).unwrap_or((0, 0, None));
            self.entries.push(MapsEntry {
                start,
                end,
                flags: vma.flags(),
                offset,
                inode,
                path,
                name: special_mapping_name(start, end, self.heap_top.load(Ordering::Relaxed)),
            });
        }
    }

    fn start(&mut self) -> Option<Self::Item> {
        self.rewind();
        self.next()
    }

    fn next(&mut self) -> Option<Self::Item> {
        let item = self.entries.get(self.next_index).cloned();
        if item.is_some() {
            self.next_index += 1;
        }
        item
    }

    fn show(&self, item: &Self::Item, buf: &mut String) -> core::fmt::Result {
        buf.push_str(&render_maps_line(item));
        Ok(())
    }
}

struct ProcFdLink {
    node: SimpleFsNode,
    task: WeakKtaskRef,
    fd: u32,
}

impl ProcFdLink {
    fn new(fs: Arc<SimpleFs>, task: WeakKtaskRef, fd: u32) -> Arc<Self> {
        Arc::new(Self {
            node: SimpleFsNode::new(
                fs,
                NodeType::Symlink,
                NodePermission::from_bits_truncate(0o777),
            ),
            task,
            fd,
        })
    }

    fn display_target(&self) -> VfsResult<String> {
        let task = self.task.upgrade().ok_or(VfsError::NotFound)?;
        task.as_thread()
            .process()
            .resources()?
            .snapshot_fd(self.fd as _)
            .map_err(|err| {
                if err == VfsError::BadFileDescriptor {
                    VfsError::NotFound
                } else {
                    err
                }
            })?
            .path()
            .display_path()
    }

    fn target_len(&self) -> VfsResult<u64> {
        Ok(self.display_target()?.len() as u64)
    }
}

impl InodeOperations for ProcFdLink {
    fn symlink_operations(&self) -> Option<&dyn InodeSymlinkOperations> {
        Some(self)
    }

    fn getattr(
        &self,
        idmap: &kvfs::MountIdmap,
        path: Option<&kvfs::Path>,
        request_mask: kvfs::GetattrRequestMask,
        query_flags: kvfs::GetattrQueryFlags,
    ) -> VfsResult<Metadata> {
        let mut metadata = self.node.getattr(idmap, path, request_mask, query_flags)?;
        metadata.size = self.target_len()?;
        Ok(metadata)
    }

    fn setattr(
        &self,
        idmap: &kvfs::MountIdmap,
        dentry: &Dentry,
        update: MetadataUpdate,
    ) -> VfsResult<MetadataUpdate> {
        self.node.setattr(idmap, dentry, update)
    }
}

impl InodeSymlinkOperations for ProcFdLink {
    fn get_link(
        &self,
        _dentry: Option<&Dentry>,
        _inode: &kvfs::VfsInode,
        _done: &mut kvfs::DelayedCall,
    ) -> VfsResult<String> {
        self.display_target()
    }
}

impl FileOperations for ProcFdLink {
    fn supports_read(&self) -> bool {
        true
    }

    fn read(&self, _file: &VfsFile, buf: &mut [u8], offset: u64) -> VfsResult<usize> {
        let target = self.display_target()?;
        let data = target.as_bytes();
        if offset >= data.len() as u64 {
            return Ok(0);
        }
        let data = &data[offset as usize..];
        let read = data.len().min(buf.len());
        buf[..read].copy_from_slice(&data[..read]);
        Ok(read)
    }

    fn magic_link(self: Arc<Self>) -> Option<Arc<dyn MagicLinkOps>> {
        Some(self)
    }
}

fn proc_fd_link_child(
    lookup: SimpleDirLookup<'_>,
    name: &str,
    link: Arc<ProcFdLink>,
) -> VfsResult<Dentry> {
    let init = link.node.inode_init().with_size(link.target_len()?);
    let inode = VfsInode::new_file_with_flags(link, NodeFlags::NON_CACHEABLE, init);
    Ok(lookup.file_from_inode(name, inode))
}

impl MagicLinkOps for ProcFdLink {
    fn readlink_display(&self) -> VfsResult<String> {
        self.display_target()
    }

    fn follow(&self, _intent: LookupIntent, flags: LookupFlags) -> VfsResult<ResolvedObject> {
        if flags.rejects_magic_links() || !flags.follows_final() {
            return Err(VfsError::FilesystemLoop);
        }

        let task = self.task.upgrade().ok_or(VfsError::NotFound)?;
        let snapshot = task
            .as_thread()
            .process()
            .resources()?
            .snapshot_fd(self.fd as _)
            .map_err(|err| {
                if err == VfsError::BadFileDescriptor {
                    VfsError::NotFound
                } else {
                    err
                }
            })?;
        Ok(ResolvedObject::location(snapshot.file().path().clone()))
    }
}


struct EmptyProcDir;

impl SimpleDirOps for EmptyProcDir {
    fn child_names<'a>(&'a self) -> VfsResult<Box<dyn Iterator<Item = Cow<'a, str>> + 'a>> {
        Ok(Box::new(iter::empty()))
    }

    fn lookup_child(&self, _lookup: SimpleDirLookup<'_>, _name: &str) -> VfsResult<Dentry> {
        Err(VfsError::NotFound)
    }

    fn supports_dentry_cache(&self) -> bool {
        false
    }

    fn link_count(&self) -> u64 {
        2
    }
}

struct ThreadFdDir {
    fs: Arc<SimpleFs>,
    task: WeakKtaskRef,
}

impl SimpleDirOps for ThreadFdDir {
    fn child_names<'a>(&'a self) -> VfsResult<Box<dyn Iterator<Item = Cow<'a, str>> + 'a>> {
        let Some(task) = self.task.upgrade() else {
            return Ok(Box::new(iter::empty()));
        };
        let Ok(resources) = task.as_thread().process().resources() else {
            return Ok(Box::new(iter::empty()));
        };
        let Ok(fd_table) = resources.fd_table() else {
            return Ok(Box::new(iter::empty()));
        };
        let ids = fd_table
            .read()
            .ids()
            .map(|id| Cow::Owned(id.to_string()))
            .collect::<Vec<_>>();
        Ok(Box::new(ids.into_iter()))
    }

    fn lookup_child(&self, lookup: SimpleDirLookup<'_>, name: &str) -> VfsResult<Dentry> {
        let fs = self.fs.clone();
        let task = self.task.upgrade().ok_or(VfsError::NotFound)?;
        let fd = name.parse::<u32>().map_err(|_| VfsError::NotFound)?;
        task.as_thread()
            .process()
            .resources()?
            .snapshot_fd(fd as _)
            .map_err(|err| {
                if err == VfsError::BadFileDescriptor {
                    VfsError::NotFound
                } else {
                    err
                }
            })?;
        proc_fd_link_child(lookup, name, ProcFdLink::new(fs, Arc::downgrade(&task), fd))
    }

    fn supports_dentry_cache(&self) -> bool {
        false
    }
}

struct ThreadDir {
    fs: Arc<SimpleFs>,
    task: WeakKtaskRef,
}

fn make_thread_dir(
    lookup: SimpleDirLookup<'_>,
    name: &str,
    fs: Arc<SimpleFs>,
    task: &KtaskRef,
) -> Dentry {
    let thread_dir = ThreadDir {
        fs: fs.clone(),
        task: Arc::downgrade(task),
    };

    #[cfg(feature = "tee")]
    if tee::has_ta_info(task) {
        let mut ext = DirMapping::new();
        ext.add_child("ta_info", {
            let fs = fs.clone();
            let task = Arc::downgrade(task);
            move |lookup, name| {
                Ok(tee::make_ta_info_dir(
                    lookup,
                    name,
                    fs.clone(),
                    task.clone(),
                ))
            }
        });
        return lookup.dir(
            name,
            SimpleDir::new_maker(fs.clone(), Arc::new(thread_dir.chain(ext))),
        );
    }

    lookup.dir(name, SimpleDir::new_maker(fs, Arc::new(thread_dir)))
}

const PROC_NS_BASE: u64 = 0xf000_0000;

fn namespace_inode(kind: &str) -> u64 {
    match kind {
        "mnt" => PROC_NS_BASE + 1,
        "pid" => PROC_NS_BASE + 2,
        "net" => PROC_NS_BASE + 3,
        "ipc" => PROC_NS_BASE + 4,
        "uts" => PROC_NS_BASE + 5,
        "user" => PROC_NS_BASE + 6,
        "cgroup" => PROC_NS_BASE + 7,
        _ => PROC_NS_BASE,
    }
}

fn namespace_link_target(kind: &str) -> String {
    format!("{kind}:[{}]", namespace_inode(kind))
}

fn task_namespace_link_target(kind: &str, task: &KtaskRef) -> VfsResult<String> {
    if kind == "cgroup" {
        let id = task
            .as_thread()
            .process()
            .cgroup_ns()
            .map_err(|_| VfsError::NotFound)?
            .id()
            .as_u64();
        Ok(format!("{kind}:[{id}]"))
    } else {
        Ok(namespace_link_target(kind))
    }
}

const PROC_NAMESPACE_KINDS: [&str; 7] = ["mnt", "pid", "net", "ipc", "uts", "user", "cgroup"];

struct ThreadNsDir {
    fs: Arc<SimpleFs>,
    task: WeakKtaskRef,
}

impl SimpleDirOps for ThreadNsDir {
    fn child_names<'a>(&'a self) -> VfsResult<Box<dyn Iterator<Item = Cow<'a, str>> + 'a>> {
        let task = self.task.upgrade().ok_or(VfsError::NotFound)?;
        let mut names = PROC_NAMESPACE_KINDS
            .iter()
            .map(|kind| Cow::Borrowed(*kind))
            .collect::<Vec<_>>();
        for kind in PROC_NAMESPACE_KINDS {
            if let Ok(target) = task_namespace_link_target(kind, &task) {
                names.push(Cow::Owned(target));
            }
        }
        Ok(Box::new(names.into_iter()))
    }

    fn lookup_child(&self, lookup: SimpleDirLookup<'_>, name: &str) -> VfsResult<Dentry> {
        let task = self.task.upgrade().ok_or(VfsError::NotFound)?;
        if PROC_NAMESPACE_KINDS.contains(&name) {
            let target = task_namespace_link_target(name, &task)?;
            return lookup.file(
                name,
                SimpleFile::new(self.fs.clone(), NodeType::Symlink, move || {
                    Ok(target.clone())
                }),
            );
        }

        for kind in PROC_NAMESPACE_KINDS {
            let Ok(target) = task_namespace_link_target(kind, &task) else {
                continue;
            };
            if target == name {
                let contents = target.clone();
                return lookup.file(
                    name,
                    SimpleFile::new_regular(self.fs.clone(), move || {
                        Ok(contents.as_bytes().to_vec())
                    }),
                );
            }
        }
        Err(VfsError::NotFound)
    }

    fn supports_dentry_cache(&self) -> bool {
        false
    }
}

impl SimpleDirOps for ThreadDir {
    fn child_names<'a>(&'a self) -> VfsResult<Box<dyn Iterator<Item = Cow<'a, str>> + 'a>> {
        Ok(Box::new(
            [
                "stat",
                "statm",
                "status",
                "smaps_rollup",
                "tree_smaps_rollup",
                "uid_map",
                "gid_map",
                "setgroups",
                "oom_score_adj",
                "task",
                "maps",
                "mounts",
                "mountinfo",
                "mountstats",
                "cgroup",
                "ns",
                "cmdline",
                "comm",
                "exe",
                "fd",
                "fdinfo",
            ]
            .into_iter()
            .map(Cow::Borrowed),
        ))
    }

    fn lookup_child(&self, lookup: SimpleDirLookup<'_>, name: &str) -> VfsResult<Dentry> {
        let fs = self.fs.clone();
        let task_weak = self.task.clone();
        match name {
            "stat" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        Ok(format!("{}", TaskStat::from_thread(&task)?).into_bytes())
                    }
                }),
            ),
            "statm" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        Ok(format_statm(&task).into_bytes())
                    }
                }),
            ),
            "smaps_rollup" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        Ok(format_smaps_rollup(&task))
                    }
                }),
            ),
            "tree_smaps_rollup" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        Ok(format_tree_smaps_rollup(&task))
                    }
                }),
            ),
            "uid_map" => lookup.file(
                name,
                user_map_file(fs.clone(), task_weak.clone(), false),
            ),
            "gid_map" => lookup.file(
                name,
                user_map_file(fs.clone(), task_weak.clone(), true),
            ),
            "setgroups" => lookup.file(
                name,
                user_setgroups_file(fs.clone(), task_weak.clone()),
            ),
            "status" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        Ok(task_status(&task))
                    }
                }),
            ),
            "oom_score_adj" => lookup.file(
                name,
                SimpleFile::new_regular(
                    fs.clone(),
                    CommandFile::new({
                        let task_weak = task_weak.clone();
                        move |req| {
                            let task = upgrade_task(&task_weak)?;
                            match req {
                                SimpleFileOperation::Read => {
                                    Ok(Some(format_oom_score_adj(task.as_thread().oom_score_adj())))
                                }
                                SimpleFileOperation::Write { data, .. } => {
                                    if let Some(value) = parse_oom_score_adj_input(data)? {
                                        if !(OOM_SCORE_ADJ_MIN..=OOM_SCORE_ADJ_MAX).contains(&value)
                                        {
                                            return Err(VfsError::InvalidInput);
                                        }
                                        task.as_thread().set_oom_score_adj(value);
                                    }
                                    Ok(None)
                                }
                            }
                        }
                    }),
                ),
            ),
            "task" => {
                let task = task_weak.upgrade().ok_or(VfsError::NotFound)?;
                Ok(lookup.dir(
                    name,
                    SimpleDir::new_maker(
                        fs.clone(),
                        Arc::new(ProcessTaskDir {
                            fs: fs.clone(),
                            process: Arc::downgrade(task.as_thread().process()),
                        }),
                    ),
                ))
            }
            "maps" => lookup.file(
                name,
                SeqFileInode::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        MapsIter::new(&task)
                    }
                }),
            ),
            "mounts" => lookup.file(
                name,
                SeqFileInode::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        let root = task
                            .as_thread()
                            .process()
                            .fs_context()
                            .map(|fs| fs.lock().root().clone())?;
                        Ok(ProcMountIter::mounts(Some(root)))
                    }
                }),
            ),
            "mountinfo" => lookup.file(
                name,
                SeqFileInode::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        let root = task
                            .as_thread()
                            .process()
                            .fs_context()
                            .map(|fs| fs.lock().root().clone())?;
                        Ok(ProcMountIter::mountinfo(Some(root)))
                    }
                }),
            ),
            "mountstats" => lookup.file(
                name,
                SeqFileInode::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        let root = task
                            .as_thread()
                            .process()
                            .fs_context()
                            .map(|fs| fs.lock().root().clone())?;
                        Ok(ProcMountIter::mountstats(Some(root)))
                    }
                }),
            ),
            "cgroup" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        let reader = current();
                        let reader = reader.try_as_thread().ok_or(VfsError::NotFound)?;
                        let view_root = reader
                            .process()
                            .cgroup_ns()
                            .map_err(|_| VfsError::NotFound)?
                            .root();
                        Ok(format!(
                            "0::{}\n",
                            task.as_thread()
                                .cgroup()
                                .ok_or(VfsError::NotFound)?
                                .path_from(&view_root)
                                .map_err(|_| VfsError::NotFound)?
                        ))
                    }
                }),
            ),
            "ns" => {
                let task = task_weak.upgrade().ok_or(VfsError::NotFound)?;
                Ok(lookup.dir(
                    name,
                    SimpleDir::new_maker(
                        fs.clone(),
                        Arc::new(ThreadNsDir {
                            fs: fs.clone(),
                            task: Arc::downgrade(&task),
                        }),
                    ),
                ))
            }
            "cmdline" => lookup.file(
                name,
                SimpleFile::new_regular(fs.clone(), {
                    let task_weak = task_weak.clone();
                    move || {
                        let task = upgrade_task(&task_weak)?;
                        let cmdline = task.as_thread().process().cmdline()?;
                        let mut buf = Vec::new();
                        for arg in cmdline.iter() {
                            buf.extend_from_slice(arg.as_bytes());
                            buf.push(0);
                        }
                        Ok(buf)
                    }
                }),
            ),
            "comm" => lookup.file(
                name,
                SimpleFile::new_regular(
                    fs.clone(),
                    CommandFile::new({
                        let task_weak = task_weak.clone();
                        move |req| {
                            let task = upgrade_task(&task_weak)?;
                            match req {
                                SimpleFileOperation::Read => {
                                    let mut bytes = vec![0; 16];
                                    let name = task.name();
                                    let copy_len = name.len().min(15);
                                    bytes[..copy_len].copy_from_slice(&name.as_bytes()[..copy_len]);
                                    bytes[copy_len] = b'\n';
                                    Ok(Some(bytes))
                                }
                                SimpleFileOperation::Write { data, .. } => {
                                    if !data.is_empty() {
                                        let mut input = [0; 16];
                                        let copy_len = data.len().min(15);
                                        input[..copy_len].copy_from_slice(&data[..copy_len]);
                                        task.set_name(
                                            CStr::from_bytes_until_nul(&input)
                                                .map_err(|_| VfsError::InvalidInput)?
                                                .to_str()
                                                .map_err(|_| VfsError::InvalidInput)?,
                                        );
                                    }
                                    Ok(None)
                                }
                            }
                        }
                    }),
                ),
            ),
            "exe" => lookup.file(
                name,
                SimpleFile::new(fs.clone(), NodeType::Symlink, {
                    let task_weak = task_weak.clone();
                    move || {
                        // Linux proc_exe_link() returns ENOENT when the task
                        // is gone: readlink is path resolution, unlike reads
                        // on an already-open status file.
                        let task = task_weak.upgrade().ok_or(VfsError::NotFound)?;
                        task.as_thread().process().exe_path()
                    }
                }),
            ),
            "fd" => {
                let task = task_weak.upgrade().ok_or(VfsError::NotFound)?;
                Ok(lookup.dir(
                    name,
                    SimpleDir::new_maker(
                        fs.clone(),
                        Arc::new(ThreadFdDir {
                            fs: fs.clone(),
                            task: Arc::downgrade(&task),
                        }),
                    ),
                ))
            }
            "fdinfo" => Ok(lookup.dir(
                name,
                SimpleDir::new_maker(fs.clone(), Arc::new(EmptyProcDir)),
            )),
            _ => Err(VfsError::NotFound),
        }
    }

    fn supports_dentry_cache(&self) -> bool {
        false
    }
}

pub(crate) struct ProcFsHandler {
    fs: Arc<SimpleFs>,
}

impl ProcFsHandler {
    pub(crate) fn new(fs: Arc<SimpleFs>) -> Self {
        Self { fs }
    }
}

impl SimpleDirOps for ProcFsHandler {
    fn child_names<'a>(&'a self) -> VfsResult<Box<dyn Iterator<Item = Cow<'a, str>> + 'a>> {
        Ok(Box::new(
            procfs::visible_processes()
                .into_iter()
                .map(|process| Cow::Owned(process.pid().to_string()))
                .chain([Cow::Borrowed("self")]),
        ))
    }

    fn lookup_child(&self, lookup: SimpleDirLookup<'_>, name: &str) -> VfsResult<Dentry> {
        if name == "self" {
            return lookup.file(
                name,
                SimpleFile::new(self.fs.clone(), NodeType::Symlink, proc_self_target),
            );
        }

        let pid = name.parse::<u32>().map_err(|_| VfsError::NotFound)?;
        let task = procfs::process_task(pid).map_err(|_| VfsError::NotFound)?;
        Ok(make_thread_dir(lookup, name, self.fs.clone(), &task))
    }

    fn supports_dentry_cache(&self) -> bool {
        false
    }
}

#[cfg(unittest)]
mod tests {
    use khal::paging::MappingFlags;
    use unittest::{assert_eq, def_test};

    use super::{
        MapsEntry, PROC_MAPS_ADDR_WIDTH, PROC_MAPS_PATH_COLUMN, format_oom_score_adj,
        format_task_status, maps_permissions, namespace_inode, namespace_link_target,
        parse_oom_score_adj_input, render_maps_line, special_mapping_name,
    };

    #[def_test]
    fn test_namespace_inode_has_expected_known_values() {
        assert_eq!(namespace_inode("mnt"), 0xf000_0001);
        assert_eq!(namespace_inode("pid"), 0xf000_0002);
        assert_eq!(namespace_inode("net"), 0xf000_0003);
    }

    #[def_test]
    fn test_namespace_inode_unknown_uses_base_value() {
        assert_eq!(namespace_inode("unknown"), 0xf000_0000);
    }

    #[def_test]
    fn test_namespace_link_target_formats_inode_reference() {
        assert_eq!(namespace_link_target("mnt"), "mnt:[4026531841]");
    }

    #[def_test]
    fn test_task_status_includes_process_name() {
        let status = format_task_status("test-bin", 12, 34, 'S', 1, None);

        assert!(status.contains("Name:\ttest-bin\n"));
        assert!(status.contains("Tgid:\t12\n"));
        assert!(status.contains("Pid:\t34\n"));
    }

    #[def_test]
    fn test_format_oom_score_adj_appends_newline() {
        assert_eq!(format_oom_score_adj(200), b"200\n");
    }

    #[def_test]
    fn test_parse_oom_score_adj_accepts_newline_terminated_input() {
        assert_eq!(parse_oom_score_adj_input(b"100\n").unwrap(), Some(100));
    }

    #[def_test]
    fn test_parse_oom_score_adj_accepts_empty_input_as_noop() {
        assert_eq!(parse_oom_score_adj_input(b"").unwrap(), None);
    }

    #[def_test]
    fn test_parse_oom_score_adj_rejects_invalid_input() {
        assert!(parse_oom_score_adj_input(b"abc\n").is_err());
    }

    #[def_test]
    fn test_maps_permissions_formats_shared_exec() {
        assert_eq!(
            maps_permissions(MappingFlags::READ | MappingFlags::EXECUTE | MappingFlags::SHARED),
            *b"r-xs"
        );
    }

    #[def_test]
    fn test_special_mapping_name_recognizes_heap_and_stack() {
        assert_eq!(
            special_mapping_name(
                super::USER_HEAP_BASE,
                super::USER_HEAP_BASE + 0x1000,
                super::USER_HEAP_BASE + 0x2000
            ),
            Some("[heap]")
        );
        assert_eq!(
            special_mapping_name(
                super::USER_STACK_TOP - 0x1000,
                super::USER_STACK_TOP,
                super::USER_HEAP_BASE
            ),
            Some("[stack]")
        );
    }

    #[def_test]
    fn test_render_maps_line_aligns_path_column() {
        let line = render_maps_line(&MapsEntry {
            start: 0x4000_0000,
            end: 0x4000_1000,
            flags: MappingFlags::READ | MappingFlags::WRITE,
            offset: 0,
            inode: 42,
            path: Some("/bin/test".into()),
            name: None,
        });

        assert_eq!(&line[..PROC_MAPS_ADDR_WIDTH], "000040000000");
        assert_eq!(line.chars().nth(PROC_MAPS_PATH_COLUMN), Some('/'));
    }
}
