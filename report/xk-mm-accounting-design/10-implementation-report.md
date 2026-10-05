# Implementation Report

## Selected Scope

Frozen design Tasks 1–2, with the current-mm high-water value and `ru_maxrss`
adapter added as the first part of the later resource phase. Implementation
target is the isolated X-Kernel branch `codex/prelim-kernel-compat` at HEAD
`80b4836` before the working changes. The T490-tested dirty source at
`c2eabd5` is not available in this checkout.

## Changed Files

- `mm/page_table/src/table64.rs`: sparse present-leaf range visitor and unit test.
- `mm/memspace/src/{stats.rs,aspace.rs,lib.rs}`: per-MM category/current/peak
  counters, map/fault/unmap/madvise/invalidate reconciliation, and snapshot API.
- `process/kprocess/src/stat.rs`: current MM snapshot consumption and proc stat
  fields, including task state, executable/data approximation, and current-mm
  peak RSS.
- `fs/filesystems/procfs/src/task_nodes/root.rs`: `statm` registration,
  Linux field order/units, status State/Threads/VmSize/VmRSS/VmHWM formatting,
  and formatter tests.
- `core/ksyscall/src/task/rusage.rs`: current-MM high-water value exposed as
  `ru_maxrss` for SELF/THREAD; fault counters and process-lifetime/child peak
  aggregation remain staged.
- Colocated design/security docs for page table, memspace, kprocess, and procfs.

The complete source diff, including new untracked module docs and `stats.rs`,
is exported at `report/patches/0012-feat-kernel-proc-memory-accounting-snapshot.patch`.

## Design Contracts Implemented

- Page-table traversal skips absent subtrees, reports huge leaves once, and does
  not mutate, allocate, fault, or flush.
- MM virtual size counts VMA base pages; resident counters count present user
  leaves by installed backing category. File-private copied frames count anon;
  device mappings are excluded.
- `statm` emits `size resident shared text 0 data 0` in base pages and seven
  zeroes for a target without an mm.
- `status` reports target task state, current group Threads count, and current
  VmSize/VmRSS/VmHWM in KiB. `ru_maxrss` is current-MM HWM in KiB for the first
  stage.

## Public API / Docs Changes

- Added public `MmMemoryUsage` and public `MmSpace::memory_usage()`.
- Added public `PageTable64::visit_present_in_range()`.
- Added `statm` as a procfs task file and documented its locking/lifecycle
  behavior.
- Added rustdoc and crate design/security documentation for the new ownership
  and no-user-data access paths.

## Known Limitations

- `VmHWM`/`ru_maxrss` currently track the current address space. Process-lifetime
  preservation across exec and max-only child aggregation are not implemented.
- `ru_minflt`/`ru_majflt` remain zero until the fault-completion contract carries
  Linux-equivalent major/retry classification and lifecycle transfer is wired.
- `statm.text` uses executable-path matching and `statm.data` uses private
  writable VMA pages as an explicitly documented approximation; exact ELF
  `data_vm + stack_vm` metadata is deferred.
- FileShared versus shmem provenance remains limited by current backing metadata.
- No claim is made about the unavailable T490 dirty source or Chromium renderer
  behavior from this branch.

## Initial Validation

- `make build` with AArch64 qemu defconfig: **PASS**; current final kernel
  artifact is under `tmp/xk-implement/target/xkmake/kplat-aarch64/release/`;
  final kernel SHA-256 is `388aa97c30c2c0255980a993c229abfc633c31a84ad3a5e790c715d6b481845a`.
- `make unittest GRAPHIC=n ACCEL=n MEM=2g SMP=4 VSOCK=n` using an isolated
  ext4 disk copy: **PASS**, 2569 passed, 0 failed, coverage profile/info/xml
  persisted in the first run; a second run after the HWM/rusage adapter again
  reached `2569 passed, 0 failed` and `UNITTEST_STATUS: ALL_TESTS_PASSED`.
  The first attempt without `VSOCK=n` was rejected by the WSL host's missing
  `/dev/vhost-vsock`; it was not treated as a product failure. The second
  coverage XML post-processing step was stopped after the profile/info/text
  artifacts were present because WSL `/mnt/e` I/O left xkmake blocked in
  `p9_client_rpc` for several minutes.
- `git diff --check`: **PASS**.

## Follow-up Risks

Implement fault sideband and process lifecycle resource totals only after
freezing file-backed major/retry classification. Recover the exact T490 source
diff before porting or claiming official Chromium evidence.
