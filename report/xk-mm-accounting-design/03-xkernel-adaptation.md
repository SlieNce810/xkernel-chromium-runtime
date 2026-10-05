# X-Kernel Adaptation Draft

## X-Kernel Design Goal

Provide kernel-owned, Linux-shaped memory and fault statistics without touching userland. Keep the implementation on the isolated upstream source branch until it can be ported to the unavailable T490 test tree.

## Adopted Linux Semantics

Preserve statm/status fields and units, per-mm current/HWM distinctions, per-thread fault counts, process aggregation across thread exit and exec, and wait/reap-only child aggregation.

## Deliberately Dropped Semantics

This phase does not add `smaps`, PSS, swap/I/O/context-switch counters, the full status field set, or user namespaces. No Linux-style exact per-CPU counters are required.

## Architecture

`MmSpace` owns current VMA/PTE-derived page categories and current-mm high water. `Thread` owns live per-thread fault counters. Process lifecycle state retains exited-thread, process-lifetime peak, and waited-child totals. Procfs and `getrusage` are read-only formatting/ABI adapters.

For the first procfs slice, executable ranges are identified from file-backed
VMAs whose path matches the process executable. `statm.data` is derived from
private writable VMA pages (including heap/stack mappings); this is an explicit
X-Kernel approximation of Linux `data_vm + stack_vm`, pending direct exec-layout
metadata.

## Components

### `mm/page_table`

- **Role:** expose an immutable sparse present-leaf walk restricted to a supplied user range; support huge leaves without scanning unmapped virtual pages.
- **Why this boundary exists:** only the page-table crate interprets hardware PTE tree shape. It reports present leaf range, page size, and flags; it does not assign Linux RSS category meaning.
- **Direct dependencies:** existing page-table primitives only.
- **Explicit non-responsibilities:** no process accounting, file provenance, or procfs policy.

### `mm/memspace`

- **Role:** compute and maintain per-mm virtual pages, anon/file/shmem resident pages, and per-mm HWM.
- **Why this boundary exists:** `MmSpace` owns VMA and PTE mutation under one sleepable mutex; it is the only stable owner for process address-space counters.
- **Direct dependencies:** existing `page_table`, VMA runtime, and page backing metadata.
- **Explicit non-responsibilities:** no user pointers, process IDs, errno formatting, or child aggregation.

### `process/kprocess`

- **Role:** expose a narrow process memory snapshot and own thread/process/child resource totals and lifecycle transfer.
- **Why this boundary exists:** `Process`/`Thread` identities outlive individual mappings and own thread exit, exec, and wait/reap relations.
- **Direct dependencies:** `memspace`, `ktask`, existing lifecycle APIs.
- **Explicit non-responsibilities:** no PTE walking, syscall ABI conversion, or VFS formatting.

### `fs/filesystems/procfs` and `core/ksyscall`

- Procfs registers/serializes `statm` and status fields; syscall code serializes `getrusage`.
- These crates must consume stable snapshots and never infer accounting from VMA flags or userland behavior.

## Data Structures

- `MmMemoryUsage` in `memspace`: page counts for virtual size, resident anon/file/shmem, shared, executable text approximation, and writable data; current-mm RSS/VM peaks.
- `ThreadFaultUsage` in `kprocess`: monotonic minor/major counters for the live thread.
- `ProcessResourceTotals` in `kprocess`: exited-thread counters, process-lifetime max RSS, and waited-child fault totals/max RSS.
- `LinuxRusageSnapshot`: immutable semantic snapshot assembled by `Process` for syscall formatting.

## Interfaces

- `MmSpace::memory_usage(&mut self) -> MmMemoryUsage`: runs with the existing mm mutex held; no I/O, faulting, or sleeping beyond the caller's MM lock. It updates read-time peaks but mutation hooks must preserve peaks before destructive changes.
- `Process::memory_usage() -> KResult<MmMemoryUsage>`: obtains a `LiveAddressSpace` capability, locks it, copies the snapshot, then releases it.
- `Thread::record_page_fault(FaultClass)`: nonblocking counter update after successful fault completion only.
- `Process::resource_usage(who) -> LinuxRusageSnapshot`: gathers thread/process/children totals using process-domain and lifecycle APIs, without holding a spinlock while acquiring the MM mutex.
- `wait_reap`: commits child resource totals only for `WaitReapMode::Consume`; WNOWAIT/peek does not change totals.

## Lifetime and Ownership Model

MM counters start with a new address space and follow its mappings. `VmHWM` resets with exec's new mm; process `ru_maxrss` is saved before old-mm teardown and survives exec. Thread fault counters transfer once at thread exit. Child counters transfer once only after a consuming wait; they include the child's already-reaped descendants.

## Locking Model

Read/modify MM stats only while holding the `MmSpace` mutex. Snapshot process thread identities and release membership/process-domain locks before acquiring MM state. Fault counters use relaxed atomics on the owning thread. Never acquire sleepable MM locks while holding process-domain or membership spinlocks.

## Failure Model

MM snapshot failure maps through existing procfs VFS errors; a target with no live mm emits seven zero statm fields and no memory block in status. Unsupported or unclassifiable major-fault paths must not silently be reported as major. All arithmetic uses checked/saturating page and byte conversions.

## Staged Rollout

1. Current `VmSize`/`VmRSS` plus statm and task State/Threads, with category-aware MM accounting.
2. Distinct per-mm and process-lifetime high-water handling across exec/exit/reap.
3. Fault sideband classification, per-thread accounting, and child aggregation.
4. Exact exec code/data/stack layout metadata and remaining status fields.

## Open Questions

- Which file-backed mapping sources are shmem versus ordinary file cache, and how is page provenance retained after private COW?
- Which successful X-Kernel file fault states correspond to Linux major versus minor, including retries?
- The current T490 build tree is not locally available; a later port/retest against its exact source is required.
