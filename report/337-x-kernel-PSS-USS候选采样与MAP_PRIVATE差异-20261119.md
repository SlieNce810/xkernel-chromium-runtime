# x-kernel PSS/USS mapcount candidate and MAP_PRIVATE mismatch (2026-11-19)

## Status

An isolated AArch64 candidate now exposes `/proc/<pid>/smaps_rollup` with numeric RSS/PSS/USS and a physical-mapcount `Shared` value. The standalone probe receives values through allocation, touch, fork, child/parent COW, and unmap. It is not yet a Linux-compatible memory result: `file_shared_touched` differs because `FilePrivateRuntime` copies file-cache bytes into anon frames on first read. This issue is recorded rather than hidden by adding calculated shared values.

## Method and patch

[procfs-smaps-rollup-mapcount.patch](../patches/compat/procfs-smaps-rollup-mapcount.patch) adds a cold-path present-page-frame walk in `mm/memspace/src/aspace.rs`; procfs scans live process address spaces, counts each physical frame mapping, and computes PSS as the mapping-weighted resident set and USS as frames with one live mapping. It adds `smaps_rollup` plus explicit `Rss`, `Pss`, `USS`, and `Shared` output. If a page-table walk cannot be completed, the procfs fields remain `UNAVAILABLE`.

The updated [procfs memory probe](../scripts/t490/procfs_memory_probe.c) accepts candidate `USS:` and `Shared:` fields and falls back to Linux `Private_*` and `Shared_*` keys. Native Linux fallback passed on T490 in [report 336](336-T490-native-Linux-procfs-memory-parser-r2-20261119.md).

The mapcount algorithm reports physical mappings faithfully, but the current MAP_PRIVATE read fault creates anon frames before a write. The pending repair needs to map a full clean file page from the page cache read-only and create an anon copy on the first write. It also needs to classify those clean file-cache pages as file-backed in `statm.shared`. No patch for that semantic repair is included in this report.

## Linux comparison

Native Linux values are in [report 336](336-T490-native-Linux-procfs-memory-parser-r2-20261119.md). Since the small process has a different resident baseline on Linux and x-kernel, the table compares changes within the same phase sequence (kB):

| Transition | Linux RSS / PSS / USS / Shared delta | x-kernel candidate RSS / PSS / USS / Shared delta | Assessment |
|---|---:|---:|---|
| anon touched | +128 / +128 / +128 / 0 | +128 / +128 / +128 / 0 | Matches |
| file-private first touch | +128 / +128 / +128 / 0 | +128 / +128 / +128 / 0 | Matches for this probe |
| file-shared touch after private mapping | +128 / 0 / -128 / +256 | +128 / +128 / +128 / 0 | Mismatch: file-private and file-shared mappings do not share one cache frame |

The candidate's later fork/COW transitions do react to physical mapcount. Parent PSS/USS/Shared moves from `330/148/364` before parent COW to `332/152/360` after; the child moves from `202/20/364` to `204/24/360`. Parent after unmap returns to RSS/PSS/USS `128/128/128` while HWM remains 512. These single-process probe results do not represent Chromium tree sampling.

## Guest evidence

The 2 GiB AArch64 pure-TCG session ran on T490 with the isolated `b73e581` worktree plus its 54 tracked/untracked candidate modifications. Kernel binary SHA-256: `71ffed0944685323b05170b62678d899c1b80e647eaca8cbabb461728ba3aaf9`; build id `bbeb3f9661fd2f3d66b71bab2517dfdb2e87bc8a5ca101db836ed2069483c80a`. The exact run package is [procfs PSS/USS C probe r1 evidence](../evidence/2026-11-19_t490-procfs-pss-uss-cprobe-r1/). Timerfd/inotify passed 11/11 and SCM_RIGHTS passed 6/6; this round's compatibility bundle exited 0.

## Remaining work

Fix MAP_PRIVATE page-cache sharing and COW classification, then rerun the same probe against Linux and x-kernel. After the single-process accounting agrees, collect Chromium process-tree RSS/PSS/USS at 1 Hz through the 60-second post-load window. No browser peak sample or before/after performance sample exists yet.

The first FilePrivate COW patch compile attempt failed before QEMU because it wrapped an already-optional file offset twice; the compiler diagnostic and no-screenshot run log are preserved in [file-private build r1 evidence](../evidence/2026-11-19_t490-file-private-build-r1/). That failed build was not used for the PSS values above. The corrected patch built successfully in [file-private build r2 evidence](../evidence/2026-11-19_t490-file-private-build-r2/), then the same C guest probe was rerun successfully; see [report 338](338-MAP_PRIVATE页缓存共享与PSS-USS-guest复测-20261119.md) and its evidence bundle.

Follow-up [report 338](338-MAP_PRIVATE页缓存共享与PSS-USS-guest复测-20261119.md) records the corrected MAP_PRIVATE candidate passing the same guest C probe with Linux-matching file-shared, fork/COW, and unmap deltas.
