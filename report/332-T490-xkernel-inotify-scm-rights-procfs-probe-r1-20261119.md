# T490 x-kernel inotify, SCM_RIGHTS, and procfs probe r1 (2026-11-19)

## Status

The first T490 AArch64 guest comparison against the native Linux references reproduced three gaps in the frozen x-kernel snapshot. This is a diagnostic finding report; none of these gaps is claimed repaired, and no compatibility PASS is inferred. The current kernel source tree was at `b73e5814087c9d33c5f0a35b66cc56be689d3dee` with 53 dirty files. The exact built kernel and disk hashes, run command, raw console, screenshot hashes, and source-file hashes are preserved in [the r1 evidence directory](../evidence/2026-11-19_t490-acceptance-compat-memory-r1/).

## Platform and run

T490 ran Ubuntu 26.04.1 / Linux 7.0.0-43-generic / x86_64 with QEMU 10.2.1. The guest was AArch64, pure TCG, 2 GiB, four vCPUs, and the configured virtio devices. Static platform compliance reported 15 PASS / 0 FAIL. The bundle ran the same `compatprobe.c` checks as the Linux reference reports 327 and 328, followed by `procfs_memory_probe.c`.

The host QEMU round lasted about 307 seconds and ended with outer rc 0. The guest bundle returned `overall_rc=1`. This was not a Chromium GUI or performance run: all six QEMU frames were 640×480 and showed “Display output is not active.” The diagnostic PPMs are retained on T490 and their hashes are in the evidence bundle. The exact non-PPM files fetched from the T490 directory are also preserved in a SHA-256-verified archive; readable local copies have LF line endings.

## Findings and source locations

| Dependency | Native Linux reference | T490 x-kernel guest | Source location / current explanation |
|---|---|---|---|
| timerfd | WSL2 Linux 5.15 and T490 Linux 7.0 pass the focused create/settime/poll/read checks; see [report 327](327-inotify-timerfd-WSL2-Linux基线与T490待补-20261119.md) and [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md). | 4/4 pass. | Timerfd behavior is not implicated by this run. |
| inotify watched-directory child create | Both Linux references pass the complete event check, including a named `IN_CREATE` event. | Initialization, watch installation, create and write syscalls return success, but `poll()` sees no readable event and the probe fails before event-read validation. | `process/kfd_objects/src/inotify.rs:111-145` installs exact-inode watches; `:159-201` matches only the notified inode and queues fixed 16-byte records; `:247-253` sets `len=0` and has no child name. The current notification call sites found in `posix/fs/src/io.rs:185,213` and `posix/fs/src/fd_ops.rs:37` cover writes and close on the file inode. No parent-directory create notification is wired into the create path. A complete repair must emit a named child event on the watched parent and represent variable-length inotify records; adding only a wakeup would not satisfy the Linux probe.
| AF_UNIX `SCM_RIGHTS` stream short read | WSL2 and T490 native Linux pass 6/6; Linux delivers the fd with the first 1-byte `recvmsg` and does not repeat it. | 4/6 pass: payload and send succeed, but no fd arrives on the first read and a later read reports one. | The T490 working snapshot’s dirty `net/knet/src/unix/stream.rs:400-467` caps reads at ancillary boundaries, decrements `bytes_remaining`, and only removes/appends a batch after `bytes_remaining` reaches zero (`:445-466`). That delays control delivery until the final byte of a write. The per-source SHA-256 values are recorded in the evidence bundle because this file was dirty relative to the recorded HEAD.
| procfs memory and shared/COW accounting | T490 native Linux exposes `smaps_rollup` RSS/PSS/USS; see [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md). | `statm` and `VmRSS` change with touched pages and unmap, but `/proc/<pid>/smaps_rollup` is not found. PSS and USS remain explicitly unavailable. The guest probe does not establish correct shared-page attribution or COW accounting. | The current dirty `fs/filesystems/procfs/src/task_nodes/root.rs:101-120,175-224` implements `statm` and `VmRSS` only; the task directory list at `:833-859` has no `smaps` or `smaps_rollup`. `mm/memspace/src/stats.rs:20-52` exposes per-address-space resident anon/file/shmem counters but no proportional/private-set aggregation across mappings and tasks.

## Reproduction and patch state

The minimum reproductions are the two modes in `scripts/t490/compatprobe.c` and the allocation/fork/COW/unmap case in `scripts/t490/procfs_memory_probe.c`. The exact frozen run command is in `evidence/2026-11-19_t490-acceptance-compat-memory-r1/launcher.sh`; raw output is in `console.log`. Linux controls are preserved in reports 327, 328, and 331.

This diagnostic round did not apply a kernel patch or run a guest regression after a fix. A later isolated candidate for SCM_RIGHTS passed the `knet::unix::stream` AArch64 QEMU module tests 24/24; the C guest probe and Mojo regression remain open. See [report 333](333-SCM_RIGHTS首字节交付候选补丁与T490流回归-20261119.md). The inotify and procfs findings in this report remain open until their patches, build identities, and guest regressions are recorded.

## Performance impact

The absent `smaps_rollup` blocks valid x-kernel PSS/USS collection for the Chromium process tree. No Chromium startup, first-frame, renderer-ready, RSS/PSS/USS peak, before/after, or optimization result was collected in this diagnostic round. Those metrics remain unavailable rather than inferred from the small standalone probe.
