# Arbiter Decision Table

| Item | Linux concern | X-Kernel concern | Decision | Phase | Rationale |
|---|---|---|---|---|---|
| statm field order and units | Seven base-page values; no-mm is seven zeroes | procfs node is absent | Must Preserve Now | 1 | Required Linux ABI and independently verifiable |
| statm resident/shared categories | anon+file+shmem; shared=file+shmem | no RSS category counters | Must Preserve Now | 1 | Do not substitute VMA sharing or physical mapcount |
| statm text/data | code range and data+stack | exec-layout fields are not committed | Preserve Later | 4 | Requires kexec/process layout ownership; avoid false numbers |
| status State/Threads | per-task state, live group count | status formatter omits both | Must Preserve Now | 1 | Current target task/thread APIs already expose the data |
| VmSize/VmRSS | KiB, current mm | no memory stats API | Must Preserve Now | 1 | Reuse VMA/PTE-owned accounting |
| VmHWM | current-mm high-water | no high-water tracking | Must Preserve Now | 2 | Track at MM commit/destructive boundaries; resets on exec |
| ru_maxrss | KiB process high-water, max waited child | rusage value fixed at zero | Must Preserve Now | 2 | Distinct process lifetime and child max aggregation |
| min/major fault counts | per-thread, success-only, major/retry class | completion lacks class and lifecycle totals | Must Preserve Now | 3 | Requires sideband classification; never guess all-resolved as minor |
| file-private COW category | physical page source controls RSS category | fileprivate first-touch copies into anon | Must Preserve Now | 1 | Count installed anon frame, not VMA's source file |
| exact full status memory block | many additional Linux fields | exec layout/RSS provenance incomplete | Preserve Later | 4 | This task is bounded to agreed status subset |
| advanced Linux MM internals | per-CPU counters, exact Linux locking | Rust MM has single owner mutex | Explicitly Dropped | all | Internal mechanism differs; ABI contract remains |
| T490 exact-tree integration | runtime proof must match source/image hashes | tested c2e tree unavailable locally | Preserve Later | after local patch | Prevents falsely claiming T490 regression closure |
