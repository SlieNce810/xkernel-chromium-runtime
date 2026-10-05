# Implementation Scope

## Frozen Design Run

`report/xk-mm-accounting-design/06-frozen-design.md`, X-Kernel HEAD `80b4836`.

## Selected Task IDs

Task 1 and Task 2 (initial current-value procfs snapshot slice).

## Owner Crates

`mm/page_table`, `mm/memspace`, `process/kprocess`, `fs/filesystems/procfs`.

## Allowed Write Set

Those kernel crate sources, their unit tests, and crate-local design/security/rustdoc required by the new contract.

## Forbidden Write Set

All root `scripts/`, `scripts/testpage/`, guest rootfs and Chromium packages, JS/CSS, shell flags, userland shims, evidence from prior runs, and T490's unavailable working tree.

## Design Contracts To Implement

- Sparse enumeration of present leaf mappings in a supplied user VMA range; skip absent subtrees and special/device leaves; count huge leaves in base pages.
- `MmSpace` provides a lock-scoped current `VmSize`/RSS category snapshot; file-private copied frames count as anon.
- Procfs emits Linux statm's seven fields and the agreed status State/Threads/VmSize/VmRSS subset with exact field order and units; no-mm targets follow Linux behavior.

## Required Documentation Updates

Update `mm/page_table/docs/design.md`, `mm/memspace/docs/design.md`, `process/kprocess/docs/design.md`, and procfs module docs where APIs/ownership change; add rustdoc for public interfaces. Do not alter unrelated module docs.

## Required Validation

Run targeted page-table/memspace/procfs unit tests and the pinned AArch64 kernel build workflow. Run QEMU TCG smoke with an unmodified rootfs copy if feasible. Record the exact source and kernel hashes; do not claim T490 acceptance.

## Stop Conditions

Stop before implementing if accurate shared/file/anon categorization cannot be derived from the current mapped-page owner, if the sparse walker would require locking or faulting outside its contract, or if the exact T490 source becomes available and changes the implementation base.
