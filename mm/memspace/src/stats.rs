// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Per-address-space memory accounting snapshot.
//!
//! 这个模块只拥有"当前 mm 的页计数"，不拥有任务 ID、syscall 结构体或
//! 子进程生命周期 —— 那些分别属于 `kprocess` 与 `procfs`。
//!
//! 单位约定（与 Linux 一致，换算只在 procfs / syscall 侧做）：
//! - 本模块内一律是 **4 KiB 基础页**；
//! - `statm` 直接输出页数；
//! - `status` / `getrusage` 输出 KiB，由调用方乘 4。
//!
//! 为什么共享页按 backing 分类而不是按物理页 mapcount：
//! 共享匿名页（memfd / shm）与共享文件页在物理页上看起来完全一样，
//! 只有在 VMA 的 backing 里才保留了来源。mapcount 推理会把 memfd 错算成
//! file，而 `statm.shared` 与 `VmRSS` 的口径都依赖这个区分。

/// 当前地址空间的内存快照，单位：4 KiB 基础页。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MmMemoryUsage {
    /// 用户 VMA 覆盖的虚拟页总数（未触碰过的 mmap 也计入）。
    pub virtual_pages: u64,
    /// 常驻的匿名页，含由私有文件映射复制出来的页（Linux `MM_ANONPAGES`）。
    pub rss_anon_pages: u64,
    /// 常驻的共享文件页（Linux `MM_FILEPAGES`）。
    pub rss_file_pages: u64,
    /// 常驻的共享匿名页，即 memfd / shm（Linux `MM_SHMEMPAGES`）。
    pub rss_shmem_pages: u64,
    /// 可执行 VMA 覆盖的页数，`statm.text` 的近似口径。
    pub text_pages: u64,
    /// 私有可写 VMA 覆盖的页数，`statm.data` 的近似口径（含 heap 与 stack）。
    pub data_pages: u64,
    /// 当前 mm 的常驻页峰值。
    pub peak_rss_pages: u64,
}

impl MmMemoryUsage {
    /// 常驻总页数 = anon + file + shmem，对应 Linux `get_mm_rss()`。
    pub const fn resident_pages(&self) -> u64 {
        self.rss_anon_pages + self.rss_file_pages + self.rss_shmem_pages
    }

    /// 共享常驻页数 = file + shmem，对应 Linux `statm.shared`。
    pub const fn shared_pages(&self) -> u64 {
        self.rss_file_pages + self.rss_shmem_pages
    }

    /// 常驻总字节数。
    pub const fn resident_bytes(&self) -> u64 {
        self.resident_pages() * memaddr::PAGE_SIZE_4K as u64
    }
}
