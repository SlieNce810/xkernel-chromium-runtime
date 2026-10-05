# Review Findings

## linux-review-of-xkernel

- Finding: `statm.shared` must be anon/file/shmem-counter-derived, not physical mapcount. Severity: important. The first adaptation draft proposed delaying on mapcount; Linux v7.0 uses file+shmem RSS counters. Correction: derive `shared` from `RssFile + RssShmem`.
- Finding: a present-PTE walk must exclude non-user/device mappings and count huge leaves in base pages. Severity: important. Correction: use an MM-owned range snapshot with explicit mapping category and validate only eligible user leaves.
- Finding: `VmHWM` and `ru_maxrss` have different lifetimes across exec. Severity: important. Correction: current-mm HWM resets with a new mm; process max RSS survives exec and is saved for child reap.
- Finding: successful fault count needs final major/minor classification and once-only retry handling. Severity: important. Correction: sideband class follows the completed fault result; failed/incomplete retries are not charged.
- Finding: the getrusage aggregation contract must include active/exited threads, wait-reaped child descendants, WNOWAIT and max-not-sum child RSS. Severity: important. Correction: transfer thread totals once and commit child totals only on consuming reap.
- Finding: status `State` is task-specific and `Threads` is the live group count. Severity: important. Correction: format each task file from its target task and current group count.

## xkernel-review-of-linux-usage

- Finding: Linux allows proc RSS approximation, so X-Kernel need not copy per-CPU counters or Linux lock internals. Severity: optional. Decision: use X-Kernel MM ownership/locking, preserve ABI semantics.
- Finding: Linux `statm.text` is the code range and `data` is data+stack, not simply all executable/writable VMAs. Severity: important. Correction: exact text/data need exec-layout metadata; do not claim VMA-permission approximations are exact.
- Finding: file-private X-Kernel first-touch currently installs anonymous copied frames. Severity: important. Correction: classify the installed page as anon, not file, regardless of the VMA source.
- Finding: no-mm statm/status behavior differs from propagating a dead-mm error. Severity: important. Correction: statm emits seven zeroes; status omits the memory block while retaining task state lines.
