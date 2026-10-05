# Validation Report

## Scope

Tasks 1–2 plus current-MM high-water adapter on X-Kernel `80b4836`.

## Commands Run

- `cp platforms/kplat-aarch64/qemu_defconfig .config && make defconfig`
- `make build`
- `make unittest GRAPHIC=n ACCEL=n MEM=2g SMP=4 VSOCK=n`
- `git diff --check`

## Results

- AArch64 release build: **PASS**.
- AArch64 QEMU pure TCG unittest: **PASS** — `2569 passed, 0 failed, 0 ignored`.
- The same unittest command was rerun after adding current-MM HWM and the
  `ru_maxrss` adapter: **PASS** — `2569 passed, 0 failed, 0 ignored`.
- New tests observed in `target/xkmake/kplat-aarch64/release/qemu.log`:
  `visit_present_in_range_skips_holes_and_reports_huge_leaf_once`,
  `memory_usage_distinguishes_virtual_and_resident_pages`,
  `memory_usage_counts_anonymous_shared_pages_as_shared`, and procfs format
  tests.
- Coverage artifacts: `default.profraw`, `coverage.info`, and `coverage.txt`
  under the AArch64 release target directory. The second run's XML conversion
  was stopped after xkmake remained blocked on WSL `/mnt/e` post-processing.
- `git diff --check`: **PASS**.
- `git apply --check report/patches/0012-feat-kernel-proc-memory-accounting-snapshot.patch`
  against a fresh current upstream checkout: **PASS** (the live upstream main
  had advanced to `37fdbaa`; this confirms patch context remains applicable).

## Design Contracts Covered

Sparse page-table traversal, current VMA virtual size, present user resident
categories, current-MM HWM, statm units/order/no-mm behavior, and status state/
thread/memory formatting.

## Untested Contracts

Default multi-process Chromium renderer startup, exact T490 source integration,
fault major/minor sideband, process-lifetime exec HWM, child wait/reap resource
aggregation, full Linux status fields, and file/shared-memory provenance beyond
the current X-Kernel backing kinds.

## Failures / Logs

The first unittest attempt failed before boot because WSL lacked
`/dev/vhost-vsock`; rerunning with `VSOCK=n` passed. The passed QEMU log is
`tmp/xk-implement/target/xkmake/kplat-aarch64/release/qemu.log`.

## Verdict

**Ready for the bounded Tasks 1–2 slice; needs follow-up before full plan
completion.**
