# Topic Brief

## Topic

Linux-compatible per-process memory and fault accounting for procfs and `getrusage(2)`.

## Scope

Design the X-Kernel ownership and reporting path for `/proc/<pid>/statm`, the `State`/`Threads` and memory fields of `/proc/<pid>/status`, and `ru_maxrss`, `ru_minflt`, and `ru_majflt` from `getrusage(2)`. Freeze units, mm/task/process lifetimes, and child wait/reap aggregation.

## Explicit Non-Goals

- No changes to browser, test-page, shell-script, guest-image, JS/CSS, or shim code.
- No full `smaps`, PSS, complete `/proc/<pid>/status` expansion, swap accounting, or unrelated MM redesign.
- No claim that this local branch reproduces the T490 test tree; the test tree at `c2eabd5` is unavailable here.
- `waitid` and the default multi-process Chromium blocker remain separate kernel tasks.

## Phase Target

Preliminary-round kernel compatibility work, implemented against the isolated upstream X-Kernel checkout at `80b4836`.

## Expected Deliverables

Linux semantic baseline, X-Kernel adaptation, cross-review, arbiter decisions, frozen design, implementation task split, and implementation/validation reports.

## Input Assumptions

- Linux source semantic baseline: upstream Linux v7.0 and matching man-pages.
- X-Kernel source baseline: `tmp/xk-implement`, branch `codex/prelim-kernel-compat`, HEAD `80b4836`.
- Base page size comes from the running architecture; do not hard-code 4 KiB in ABI conversion.

## Blocking Open Questions

- No local checkout of the exact dirty T490 source is available, so integration with its uncommitted fixes must be reported as unverified.
- X-Kernel file faults do not yet expose Linux-equivalent major/retry classification; implementation must not guess it from a generic `Resolved` result.
