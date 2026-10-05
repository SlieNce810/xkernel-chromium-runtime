# Linux Semantic Baseline

## Design Purpose

Define the ABI visible through procfs and `getrusage(2)`. Reference source is Linus Torvalds Linux v7.0; user-facing definitions are in Linux man-pages.

## User-visible Semantics

- `/proc/<pid>/statm` has seven base-page fields in order: `size`, `resident`, `shared`, `text`, `lib`, `data`, `dt`. `size` is virtual pages; `resident` is anon+file+shmem RSS; `shared` is file+shmem RSS; `text` is the aligned code range; `lib` and `dt` are zero; `data` is data plus stack pages. A task without an mm produces seven zeroes.
- `/proc/<pid>/status` reports task-specific `State` and group-wide live `Threads`. It reports the memory block only when the task has an mm. `VmSize`, `VmRSS`, and `VmHWM` are KiB (1024-byte units); `VmHWM` is the current mm's historical RSS high-water mark.
- `getrusage` returns `ru_maxrss` in KiB. SELF and THREAD use the current mm's high-water state plus saved process accounting; THREAD fault counts are per caller. CHILDREN includes only terminated children actually waited/reaped; fault counts are summed and `ru_maxrss` is the maximum child value, not a sum.
- Fault counts are charged only after successful completion. Linux classifies a completed fault as major when its final result carries `VM_FAULT_MAJOR` or the fault has the tried/retry flag; otherwise it is minor. Failed or incomplete retries are not charged. SELF sums live and exited threads; child totals are committed once on consuming wait/reap, including already-reaped descendants. Resource usage survives exec.

## Core Data Structures

- Linux `mm_struct` owns current virtual/resident RSS values and per-mm RSS high-water state.
- Linux `task_struct` owns per-thread minor/major counters; `signal_struct` stores exited-thread/process and waited-child aggregates.

## Key Code Paths

- `fs/proc/task_mmu.c`: `task_mem()` and `task_statm()` produce memory values and units.
- `fs/proc/base.c`: `proc_pid_statm()` emits the seven fields and handles no-mm targets.
- `fs/proc/array.c`: `task_state()`, `task_sig()`, and `proc_pid_status()` emit task state, Threads, and status memory fields.
- `mm/memory.c`: successful fault accounting and major/minor classification.
- `kernel/exit.c` and `kernel/sys.c`: thread-exit transfer, child reaping, and `getrusage` aggregation.

## Locking and Lifetime Rules

Linux protects MM counters independently from VMA locks, permits approximate proc RSS snapshots, records current-mm HWM separately from process-lifetime `ru_maxrss`, and transfers per-thread/child totals before the associated task/mm state is destroyed.

## Important Invariants

- Keep current RSS distinct from HWM.
- Keep `VmHWM` current-mm scoped and `ru_maxrss` process-lifetime scoped across exec.
- Count only successful final faults and only consumed child waits.
- Keep page and KiB units distinct.

## Linux Compatibility Requirements

Preserve the field ordering, units, no-mm behavior, fault classification, thread aggregation, exec persistence, and wait/reap semantics above.

## Simplification Candidates

The X-Kernel may use a single mm lock and ordinary counters instead of Linux per-CPU machinery. Proc RSS snapshots may be approximate; the reported values must still represent the right categories and lifetimes.

## Test Scenarios

Map without touching pages, fault pages in, unmap after a peak, test anon/file/shmem mappings, exercise COW, exit a thread, exec, reap a child, use WNOWAIT, and read proc files on a task without an mm.

## Source Index

- [Linux v7.0 `task_mmu.c`](https://github.com/torvalds/linux/blob/v7.0/fs/proc/task_mmu.c#L34-L96)
- [Linux v7.0 `array.c`](https://github.com/torvalds/linux/blob/v7.0/fs/proc/array.c#L117-L275)
- [Linux v7.0 `memory.c`](https://github.com/torvalds/linux/blob/v7.0/mm/memory.c#L6075-L6116)
- [Linux v7.0 `sys.c`](https://github.com/torvalds/linux/blob/v7.0/kernel/sys.c#L1735-L1838)
- [Linux v7.0 `exit.c`](https://github.com/torvalds/linux/blob/v7.0/kernel/exit.c#L182-L205)
- [Linux `/proc` documentation](https://docs.kernel.org/filesystems/proc.html), [getrusage(2)](https://www.man7.org/linux/man-pages/man2/getrusage.2.html)
