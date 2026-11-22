# T490 x-kernel compatibility and memory probe — r1

Run tag: `codex-2026-11-19_092900-compat-memory-baseline-r1`

Host run: 2026-11-19 09:34:47–09:39:54 +08:00

T490 evidence source: `/home/mo/xk6/evidence/2026-11-19_t490-codex-2026-11-19_092900-compat-memory-baseline-r1`

## Scope and exact platform

- T490 native host: Ubuntu 26.04.1, Linux `7.0.0-43-generic`, x86_64, Intel Core i7-8665U, 14.7 GiB RAM, QEMU 10.2.1.
- Guest: AArch64, QEMU 10.2.1, pure TCG (`ACCEL=n`), `-m 2g`, four vCPUs, virtio GPU/input/block/network. The complete command and environment are in `cmd.txt` and `env.txt`.
- Static platform checker: 15 PASS / 0 FAIL. This does not override the observed inactive display output and wrong screenshot size in this diagnostic round.
- Kernel source: `/home/mo/x-kernel`, HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`, with 53 pre-existing dirty files. Kernel binary SHA-256: `51c4028594e4aff9fc5b9964c4294a2904621c93e84093ac711858c454aed284`; disk image SHA-256: `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`.
- The guest autorun invoked `compatprobe --inotify-timerfd`, `compatprobe --scm-rights-shortread`, and `procfs_memory_probe`. The probe source and runner are in `scripts/t490/`; their copied hashes and injected-file hashes are recorded by `build-manifest.txt` and `round-launcher.log`.

## Results

| Area | Result | Evidence |
|---|---|---|
| timerfd | 4/4 PASS: create, one-shot settime, poll readiness, 8-byte expiration count | `console.log` |
| inotify directory create | 5 checks pass; `poll()` returns 0 after creating a watched child, so matching event read is skipped; probe exits 1 | `console.log`, source analysis in report 332 |
| AF_UNIX `SCM_RIGHTS` short reads | 4/6 PASS; the first 1-byte receive gets no fd and a later read unexpectedly reports an fd; the 100-byte payload remains intact | `console.log`, source analysis in report 332 |
| procfs memory | `statm`/`VmRSS` respond to touched pages and unmap; `smaps_rollup` is absent and PSS/USS are `UNAVAILABLE` in every phase | `console.log` |
| GUI/browser | Not measured. The monitor frames show “Display output is not active.” All six raw frames are identical 640×480 images, outside the required 1280×800 acceptance size. No Chromium process, page assertion, or input action was part of this probe. | `ppm-sha256.txt`, `ppm-summary.txt`, `screenshots/shot-06-final.png` |
| harness | QEMU session ended normally (`round-exit-code.txt` is 0); the guest bundle correctly reports `overall_rc=1` because the inotify and SCM_RIGHTS probes failed. | `console.log`, `round-launcher.log` |

This five-minute diagnostic round is not a cold-start, browser-function, 30-minute stability, or performance sample. The outer harness exit code does not turn the guest probe failures into passes.

## Raw screenshots

Raw PPM frames remain on the T490 host at the source path above. `ppm-sha256.txt` records their six remote SHA-256 values. PNG derivatives of the first and final frames are included here for quick review; they are blank diagnostic frames, not visual acceptance evidence.

The exact non-PPM files fetched from the T490 run directory are preserved in `remote-raw-evidence-nonppm.tar.gz`; its T490-computed hash and remote path are in `remote-raw-evidence-sha256.txt`. The loose text/JSON files in this directory use LF line endings for readable diffs.

## Reproduction

From the repository root on the T490 Linux host, after confirming the recorded frozen image and kernel state:

```bash
TAG=codex-2026-11-19_092900-compat-memory-baseline-r1
RCFILE=/home/mo/xk6/tmp/codex-2026-11-19_092900-compat-memory-baseline-r1.rc
env -u PLAT_MEM_OVERRIDE \
  BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img \
  ASSERT_PROFILE=legacy STRICT_GATE=0 FIRST_SHOT=60 \
  bash scripts/t490/t490_round.sh "$TAG" 300 60 \
  autorun_compat_memory_bundle.sh compatprobe.c procfs_memory_probe.c
```

The round launcher captures the host command and logs. The `.rc` file reports the outer QEMU session result; `console.log` contains the per-probe return codes and must be checked separately.
