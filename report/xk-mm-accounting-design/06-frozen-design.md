# Frozen Design

## Scope

Implement a staged, kernel-only process-memory accounting contract for the upstream `80b4836` source branch. Phase 1 owns procfs State/Threads and current `VmSize`, `VmRSS`, `VmHWM`, plus the complete seven-field statm shape with correctly categorized current pages. Later dependent phases add process-lifetime exec/reap HWM preservation, `getrusage` fault counters, and exact exec-layout fields.

## Linux Semantic Baseline

Use the v7.0 contracts in `02-linux-baseline.md`: statm is seven base-page fields; status and rusage values use KiB; shared means file+shmem RSS; current RSS and high water are distinct; fault and waited-child aggregation follow task/process lifecycle.

## Accepted X-Kernel Design Decisions

- `MmSpace` owns current VM/RSS page categories; procfs never derives RSS from the VMA alone.
- Count only eligible user mappings; exclude device/PFN mappings from process resident RSS.
- A FilePrivate page created by the current X-Kernel implementation is counted as anon because it is copied into an anonymous frame.
- `statm.text` uses executable VMAs for the main executable path; `statm.data` uses private writable VMA pages, including heap/stack. The latter is documented as an adaptation until exec-layout metadata is explicit.
- `VmHWM` is per current mm. Process `ru_maxrss` is retained separately across exec and copied into child accounting before mm teardown.
- Fault classification is explicit sideband data attached to a successfully completed fault; retries/errors do not increment counters.
- Procfs/syscall code formats immutable snapshots after releasing MM and process locks.

## Architecture

`page_table` supplies an immutable sparse walk over present leaves in a range. `memspace` interprets VMA backing and applies page deltas to per-mm anon/file/shmem counters and peaks. `kprocess` combines per-mm snapshots with per-thread and lifecycle totals. `procfs`/`ksyscall` expose Linux ABI layouts and units.

## Crate Decomposition

### `page_table`

- Purpose: enumerate present leaf mappings in a user range, including huge leaves.
- Owned concepts: page-table tree traversal and leaf attributes.
- Depends on: architecture metadata/PTE handlers.
- Must not own: RSS categories, process/task accounting.
- Phase status: now.

### `memspace`

- Purpose: maintain current per-mm virtual and resident page counts and per-mm HWM.
- Owned concepts: VMA totals, present-user-leaf range scans, category deltas at successful map/fault/unmap/invalidation boundaries.
- Depends on: `page_table`, VMA backing metadata.
- Must not own: task IDs, syscall structs, child lifecycle.
- Phase status: now and HWM phase.

### `kprocess`

- Purpose: provide narrow memory/resource snapshots and maintain thread/process/child totals.
- Owned concepts: Thread fault counters; exited-thread totals; process-lifetime max RSS; consumed-child totals.
- Depends on: `memspace`, `ktask`.
- Must not own: page-table interpretation or procfs formatting.
- Phase status: staged.

### `procfs` and `ksyscall`

- Purpose: wire-format serialization only.
- Owned concepts: statm/status rows and rusage ABI conversion.
- Must not own: new accounting counters or page walks.
- Phase status: now.

## Data Structures

- `MmMemoryUsage` (`memspace`): `virtual_pages`, `rss_anon_pages`, `rss_file_pages`, `rss_shmem_pages`, `peak_rss_pages`, `peak_virtual_pages`; shared and total resident are derived sums.
- `FaultClass` (`memspace`): successful `Minor` or successful `Major`; retry/error remains uncharged.
- `ThreadFaultUsage` (`kprocess`): atomic minor/major values.
- `ProcessResourceTotals` (`kprocess`): exited-thread totals, process-lifetime max RSS, and consumed-child totals/max.
- `LinuxRusageSnapshot` (`kprocess`): immutable selected fields for syscall formatting.

## Interfaces

- `PageTable64::visit_present_in_range(range, callback)`: callback receives leaf base, leaf size, and flags; skips empty branches and reports huge pages once.
- `MmSpace::memory_usage(&mut self) -> MmMemoryUsage`: called only while holding the MM mutex; no I/O, allocations, page faulting, or blocking backend calls.
- `MmSpace::account_fault_completion(...)`: applies one successful fault's category delta and HWM update at its final commit.
- `Process::memory_usage() -> KResult<MmMemoryUsage)`: holds a `LiveAddressSpace` capability only long enough to copy an immutable snapshot.
- `Thread::record_page_fault(FaultClass)`: relaxed atomic update after final successful fault.
- `Process::resource_usage(who) -> LinuxRusageSnapshot`: snapshots current process/thread/MM and saved lifecycle totals without acquiring the MM mutex under a spinlock.
- `wait_reap`: merges the child's saved resource totals only when the zombie is consumed.

## Lifetime and Locking

Current mm counters initialize with a new `MmSpace`; `VmHWM` resets on exec. Before the last mm handle is detached, current mm peak is saved to stable process resource totals. Thread totals transfer exactly once during thread exit. Waited child totals commit exactly once under consuming wait; WNOWAIT is observation only. MM locks are sleepable and never acquired while process-domain/member spinlocks are held.

## State Machines and Key Flows

1. Successful mapping/fault commits adjust current category counters; fault failures and incomplete retries do not.
2. Unmap, `madvise`, invalidate, mremap, and teardown subtract current resident pages while preserving the current-mm peak.
3. Exec saves old process resource peaks, installs a new mm with independent `VmHWM`, and retains process-lifetime `ru_maxrss`/fault totals.
4. Thread exit folds its faults into the process; child reap folds child totals and descendants exactly once.
5. Procfs/getrusage take immutable snapshots and serialize outside accounting locks.

## Compatibility Matrix

| Output | Unit | Source | Lifetime |
|---|---|---|---|
| statm size/resident/shared/text/lib/data/dt | base pages | MM snapshot + exec layout | current mm |
| status State/Threads | text/count | target task + thread group | current snapshot |
| VmSize/VmRSS/VmHWM | KiB | MM snapshot/current-mm peak | current mm |
| rusage ru_maxrss | KiB | process saved peak + current mm | process lifetime; children max on reap |
| rusage minflt/majflt | count | successful fault class | thread/process/consumed children |

## Deferred Items and Non-Goals

Exact text/data/stack layout requires exec metadata. Full status memory fields, exact RSS provenance for uncommon mapping types, PSS, swap, and non-memory rusage counters are deferred. Integration into the unavailable T490 dirty tree is a separate port/validation step.

## Risks and Open Follow-ups

- Sparse page-table walk must filter user/device mappings and count huge leaves in base pages.
- FileShared versus shmem provenance must use backing-object facts; FilePrivate installed anon pages are anon.
- `core/kruntime` test-only direct page-table access must not bypass production accounting.
- Major classification must be based on completion metadata, not generic `Retry` or a guess from errno.
