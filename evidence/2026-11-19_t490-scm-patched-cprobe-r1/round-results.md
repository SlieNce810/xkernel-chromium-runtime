# Patched SCM_RIGHTS C guest probe — T490 r1

Run tag: `codex-2026-11-19_105200-scm-rights-patched-cprobe-r1`

## Result

The same `compatprobe --scm-rights-shortread` that failed 4/6 on the frozen guest now passes 6/6 with the isolated candidate kernel. The descriptor arrives with the first 1-byte `recvmsg`, does not repeat on later reads, and the 100-byte payload remains intact. The earlier AArch64 QEMU stream module regression passed 24/24, including the first-partial-read ancillary case; see [report 333](../../report/333-SCM_RIGHTS首字节交付候选补丁与T490流回归-20261119.md).

The same bundle still reports `inotify_timerfd` as 9/10: timerfd checks pass and the watched-directory create event still fails to become readable. The procfs probe reports `statm`/`VmRSS` changes, while `smaps_rollup`, PSS, and USS remain unavailable. Therefore the guest bundle `overall_rc=1` and the full compatibility task remains incomplete.

## Run conditions

- T490 host: Ubuntu 26.04.1, Linux `7.0.0-43-generic`, x86_64; QEMU 10.2.1.
- Candidate source tree: `/home/mo/xk6/worktrees/xk-compat-fix-r1`, HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`, 53 dirty files.
- QEMU guest: AArch64, pure TCG, 2 GiB, four vCPUs, virtio GPU/input/block/network. Static platform gate: 15/15 pass.
- QEMU window: 303.3 seconds. Outer session exit is 0; guest compatibility bundle exit is 1 due to the remaining inotify failure.
- Candidate kernel SHA-256: `e218da29cd33538548d703de92752e63cf8ae528ec191ab78254f10418325dc9`; guest `config_sha256=128e17a1045d6b541ebf71c0f031f4a1d879f0622e3334ea343df486dded6a83`; `build_id=c9c0115893f78656051a4a87c46c2d69f22295d3ce77c8922bb03662e48a2e0`.

## GUI evidence limits

This was a compatibility probe, not a Chromium GUI, cold-start, stability, or performance run. Five monitor screenshots were captured, but each is 640×480 and displays “Display output is not active”; raw PPM files remain on T490 with SHA-256 values in `ppm-sha256.txt`. PNG previews are included only to make that inactive display state visible.

## Reproduction

Run `launcher.sh` from the T490 `/home/mo/xk6` directory. It directs `t490_round.sh` to the isolated candidate `KERNEL_DIR` and uses the recorded 2 GiB base image. The complete QEMU command, original console, round wrapper log, environment, source and image hashes, timestamps, screenshot verdicts, and remote SHA-256 manifest are preserved in this directory.
