#!/usr/bin/env python3
"""P4 补丁应用器：madvise 的 advice 白名单 + 容忍未映射空洞。

背景（全部有 errno 级证据，tag r5 / r7 探针实测）
------------------------------------------------
| 调用                                           | x-kernel      | Linux |
|------------------------------------------------|---------------|-------|
| `madvise(addr, len, MADV_DONTNEED)` 跨未映射空洞 | **ENOMEM(12)** | 0     |
| `madvise(addr, len, MADV_NORMAL)`              | **EINVAL(22)** | 0     |
| `madvise(addr, len, MADV_WILLNEED)`            | **EINVAL(22)** | 0     |
| `madvise(addr, len, MADV_FREE)`                | **EINVAL(22)** | 0     |

Linux `madvise(2)` 只对两种情况报错：`addr` 未页对齐（EINVAL）、地址区间超出地址空间（ENOMEM）。
它**不要求**区间被 VMA 完整覆盖（未映射的部分直接忽略），也**不拒绝**这些"建议性" advice。

两处根因
--------
1. `posix/mm/src/mmap.rs::MadviseRequest::dontneed_from_raw()`
   `if advice != MADV_DONTNEED { return Err(KError::InvalidInput) }` —— advice 白名单只有一项。
   注：现有单测 `madvise_request_rejects_unsupported_advice` 用的是 `999`，不在白名单里，
   因此**不需要改**。
2. `mm/memspace/src/aspace.rs::madvise_dontneed()`
   用 `covering_vmas_in_range(range)?`，该函数**要求区间被 VMA 连续覆盖**，遇洞即 `NoMemory`(=ENOMEM)。
   同文件的 `self.vmas.collect_overlapping(range)` 是容忍空洞的原语（`covering_vmas_in_range`
   自身就是用它再补一个连续性检查）。

修法：保留"页对齐 + 在地址空间内"的校验（与 Linux 一致），去掉"必须被 VMA 完整覆盖"这一条；
advice 白名单扩展到 MADV_NORMAL/RANDOM/SEQUENTIAL/WILLNEED/FREE，且只有 DONTNEED 有实际动作，
其余按 Linux 允许的"可忽略提示"处理（返回 0）。

不改的东西（刻意）
------------------
- `munmap` 跨洞：实测 rc=0，**无缺口，不动**。
- `prctl(PR_SET_PDEATHSIG)` → EINVAL：确实缺，但"接受并返回 0"等于**说谎**
  （信号根本不会被投递）。诚实的修法是记录信号并在父线程退出时投递，
  属于新功能而非 errno 修正，本轮**不夹带**（见 report/13 §4.1.1 的 G16）。
"""

import sys
from pathlib import Path

MMAP = "posix/mm/src/mmap.rs"
ASPACE = "mm/memspace/src/aspace.rs"

OLD_ADVICE = """        if advice != MADV_DONTNEED as i32 {
            return Err(KError::InvalidInput);
        }
"""

NEW_ADVICE = """        // Linux accepts the advisory hints below and is free to ignore them;
        // allocators and runtimes rely on that (glibc malloc arenas use
        // MADV_DONTNEED, PartitionAlloc/V8 use MADV_FREE). Rejecting them with
        // EINVAL is an errno Linux never produces for a well-formed call.
        // Only DONTNEED has an observable effect in this implementation, so the
        // rest are accepted as no-ops.
        match advice as u32 {
            MADV_NORMAL | MADV_RANDOM | MADV_SEQUENTIAL | MADV_WILLNEED | MADV_FREE => {
                return Ok(None);
            }
            MADV_DONTNEED => {}
            _ => return Err(KError::InvalidInput),
        }
"""

OLD_COVER = """    pub fn madvise_dontneed(&mut self, start: VirtAddr, size: usize) -> KResult {
        self.drain_pending_invalidations();
        self.validate_region(start, size)?;
        let range = VirtAddrRange::from_start_size(start, size);
        let overlapped_vmas = self.covering_vmas_in_range(range)?;
"""

NEW_COVER = """    pub fn madvise_dontneed(&mut self, start: VirtAddr, size: usize) -> KResult {
        self.drain_pending_invalidations();
        self.validate_region(start, size)?;
        let range = VirtAddrRange::from_start_size(start, size);
        // Linux applies MADV_DONTNEED to whatever part of the range is mapped
        // and silently ignores unmapped gaps; `madvise(2)` only rejects a
        // misaligned addr or a range outside the address space (both still
        // enforced by `validate_region` above). Demanding that the range be
        // fully covered by VMAs returned ENOMEM where Linux succeeds, which
        // user space does not expect.
        let overlapped_vmas = self.vmas.collect_overlapping(range);
"""

OLD_TEST_NAME = "    fn madvise_dontneed_requires_fully_mapped_range() {"
NEW_TEST_NAME = "    fn madvise_dontneed_tolerates_unmapped_gaps() {"

OLD_TEST_ASSERT = """        assert!(
            aspace.madvise_dontneed(start, PAGE_SIZE_4K * 3).is_err(),
            "range with an unmapped gap must not be partially discarded"
        );
        assert!(
            aspace.pgtbl.modify().query(start).is_ok(),
            "failed MADV_DONTNEED must leave existing PTEs intact"
        );
"""

NEW_TEST_ASSERT = """        aspace
            .madvise_dontneed(start, PAGE_SIZE_4K * 3)
            .expect("Linux tolerates an unmapped gap inside the MADV_DONTNEED range");
        assert!(
            aspace.pgtbl.modify().query(start).is_err(),
            "the mapped page inside the range must still be discarded despite the gap"
        );
"""

EDITS = [
    (MMAP, OLD_ADVICE, NEW_ADVICE, "MADV_* advice 白名单"),
    (ASPACE, OLD_COVER, NEW_COVER, "madvise_dontneed 容忍未映射空洞"),
    (ASPACE, OLD_TEST_NAME, NEW_TEST_NAME, "单测改名"),
    (ASPACE, OLD_TEST_ASSERT, NEW_TEST_ASSERT, "单测断言改为 Linux 语义"),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    if not (root / MMAP).is_file():
        print(f"[!!] 不是 x-kernel 仓库根: {root}")
        return 1

    # 幂等判定
    mmap_text = (root / MMAP).read_text(encoding="utf-8")
    if "MADV_NORMAL | MADV_RANDOM | MADV_SEQUENTIAL | MADV_WILLNEED | MADV_FREE" in mmap_text:
        print("[skip] P4 似乎已应用（mmap.rs 已含 advice 白名单）")
        return 0

    applied = 0
    for rel, old, new, desc in EDITS:
        p = root / rel
        text = p.read_text(encoding="utf-8")
        n = text.count(old)
        if n == 0:
            print(f"[!!] {rel}: 找不到锚点（{desc}）—— 拒绝盲改")
            return 1
        if n > 1:
            print(f"[!!] {rel}: 锚点出现 {n} 次（{desc}）—— 拒绝盲改")
            return 1
        p.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"[ok] {rel}: {desc}")
        applied += 1

    print(f"[done] P4 应用完成，共 {applied} 处改动")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
