# Implementation Task Split

## Task List

1. Task: Add sparse present-leaf traversal and MM category accounting. Target crate: `mm/page_table`, `mm/memspace`. Structures/interfaces: range visitor, `MmMemoryUsage`, successful fault/map/unmap deltas and current-mm peak. Prerequisites: frozen design. Validation: page-table and memspace unit tests for empty/sparse/huge/user/device mappings, lazy VMA size versus resident, shared/fileprivate categories, peak surviving unmap. Done when: snapshot values have one MM owner and no full virtual-range scan.
2. Task: Expose current snapshots to procfs. Target crate: `process/kprocess`, `fs/filesystems/procfs`. Structures/interfaces: Process memory facade, `TaskStat` state/thread/memory fields, statm node. Prerequisites: Task 1. Validation: no-mm seven zeroes, seven-field order/page units, status state/thread group values, KiB conversions, teardown races. Done when: procfs output matches the frozen field contract.
3. Task: Maintain and preserve HWM. Target crate: `mm/memspace`, `process/kprocess`, `posix/process`, `process/kexec`. Structures/interfaces: per-mm VmHWM and process-lifetime max RSS. Prerequisites: Tasks 1–2. Validation: peak then unmap, exec reset/current-mm distinction, process ru_maxrss preservation, child peak max. Done when: no decrease path loses a previously committed high-water value.
4. Task: Add fault classification and lifecycle aggregation. Target crate: VFS/filemap/memspace/process/kprocess/posix-process/ksyscall. Structures/interfaces: completed-fault `FaultClass`, Thread atomics, exited-thread and waited-child totals, rusage snapshot. Prerequisites: Linux source contract review and explicit file-backed/retry classification. Validation: anonymous/COW/file faults, failed fault no count, thread exit, fork, WNOWAIT, consuming reap and descendants, exec retention. Done when: counts are charged once after successful completion and rusage unit/aggregation is correct.
5. Task: Port the finalized patch series to the exact T490-tested source and run the official Chromium scenario. Target crate: same kernel-only files. Prerequisites: source/diff recovery for `c2eabd5` and current userland image hashes. Validation: TCG run with default multi-process mode, renderer child, static page, and existing single-process diagnostic baseline. Done when: evidence manifest identifies exact source and binary hashes.

## Dependency Order

Task 1 → Task 2 → Task 3 → Task 4 → Task 5.

## Crate Build Order

`page_table` → `memspace` → `kprocess` → `procfs`/`ksyscall` → `posix-process`/`kexec` → full kernel.

## Linux Compatibility Checks

Use Linux v7.0 for units, field semantics, task/thread scope, fault completion, exec persistence, and child wait/reap semantics. Use standard Linux probes as behavior comparators; do not change their source for this work.

## Deferred Tasks

`waitid`, inotify, DRM errno, upstream submission, full status fields, and performance tuning stay separate from this MM accounting task unless later evidence ties them to the renderer blocker.
