# Named inotify child event — patched T490 C guest probe r1

Run tag: `codex-2026-11-19_111700-inotify-create-named-event-r1`

## Result

The original `compatprobe --inotify-timerfd` now passes 11/11, including `poll()` readiness and reading a named `IN_CREATE` record from a watched directory. The same run passes timerfd 4/4 and SCM_RIGHTS short reads 6/6; the compatibility bundle returns overall rc 0. This is the regression run for [inotify-named-child-events.patch](../../patches/compat/inotify-named-child-events.patch), alongside the SCM_RIGHTS candidate patch.

The memory probe still reports `statm`/`VmRSS` changes, but `/proc/<pid>/smaps_rollup` remains absent and PSS/USS are `UNAVAILABLE`; COW/shared attribution and Chromium process-tree peaks remain open.

## Run conditions

- T490 host: Ubuntu 26.04.1 / Linux `7.0.0-43-generic` / x86_64; QEMU 10.2.1.
- Isolated source tree: `/home/mo/xk6/worktrees/xk-compat-fix-r1`, HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`, 54 dirty files after applying the inotify patch.
- Guest: AArch64, pure TCG, 2 GiB, four vCPUs, virtio GPU/input/block/network. Static platform check 15/15 PASS.
- QEMU observed for 306.6 seconds; all six screendumps passed the session pixel gate. The diagnostic screen remains 640×480 and says “Display output is not active,” so this is not browser GUI evidence.
- Candidate kernel SHA-256: `3f36730b82a7154e544c1a0e78c4a415ca1727604492c88047a32b00ac9c15ba`; `config_sha256=128e17a1045d6b541ebf71c0f031f4a1d879f0622e3334ea343df486dded6a83`; `build_id=f3ea1883c2b6231c27c9934ddb09cb83c281571878e4399b1b240e09d4eafa0d`.

The original `/home/mo/x-kernel` was not modified. Raw PPMs remain on T490; this directory contains remote SHA-256 manifests and PNG previews only. Full command, console, wrapper logs, environment, source hashes, event results, and screenshot verdicts are preserved here.

## Reproduction

Run `launcher.sh` from `/home/mo/xk6`. It directs the shared round scripts to the isolated `KERNEL_DIR` and uses the recorded `pkg-installed.img` base. The matching platform `run-session.py --dry-run` is preserved in [patched dry-run r1](../2026-11-19_t490-scm-patched-dryrun-r1/).
