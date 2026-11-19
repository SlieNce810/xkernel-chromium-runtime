# PSS/USS mapcount candidate C guest probe — T490 r1

Run tag: `codex-2026-11-19_122600-procfs-pss-uss-cprobe-r1`

The isolated candidate kernel emits numeric RSS/PSS/USS/Shared through `smaps_rollup`; fork/COW/unmap values move, and PSS/USS return to baseline after unmap. The file-shared transition differs from native Linux because MAP_PRIVATE still copies on first read. See [report 337](../../report/337-x-kernel-PSS-USS候选采样与MAP_PRIVATE差异-20261119.md) for the comparison and fix direction.

The same run passed timerfd/inotify 11/11 and SCM_RIGHTS 6/6. The single-process memory probe exited 0. This was not Chromium process-tree sampling or a performance run. QEMU monitor screenshots remain diagnostic-only; raw PPMs stay on T490 with their remote hashes in `ppm-sha256.txt`.
