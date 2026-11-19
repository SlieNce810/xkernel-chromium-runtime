# MAP_PRIVATE page-cache sharing and PSS/USS guest rerun (2026-11-19)

## Result

After applying [file-private-pagecache-cow.patch](../patches/compat/file-private-pagecache-cow.patch) on top of the PSS mapcount candidate, the same AArch64 2 GiB guest probe now follows the Linux file-sharing deltas. A clean `MAP_PRIVATE` read maps the page-cache folio read-only; the first write removes that PTE and creates the anon COW page. `statm.shared` classification uses the FilePrivate runtime to distinguish page-cache frames from COW frames.

The `file_shared_touched` transition changed from the r1 mismatch to RSS +128 kB, PSS unchanged, USS −128 kB, Shared +256 kB, matching the native Linux reference pattern in [report 336](336-T490-native-Linux-procfs-memory-parser-r2-20261119.md). Parent/child COW produces matching deltas: after parent COW PSS +4 kB, USS +8 kB, Shared −8 kB; after unmap, RSS/PSS/USS return to baseline while VmHWM remains 512 kB.

All focused guest checks passed in this run: timerfd/inotify 11/11, SCM_RIGHTS short-read 6/6, and the memory probe completed with numeric RSS/PSS/USS values at every phase. The compatibility bundle returned overall rc 0.

## Candidate values (kB)

| Phase | RSS | PSS | USS | Shared |
|---|---:|---:|---:|---:|
| baseline | 128 | 128 | 128 | 0 |
| anon touched | 256 | 256 | 256 | 0 |
| file-private touched | 384 | 384 | 384 | 0 |
| file-shared touched | 512 | 384 | 256 | 256 |
| child after child COW | 228 | 123 | 20 | 208 |
| parent before parent COW | 512 | 281 | 52 | 460 |
| parent after parent COW | 512 | 285 | 60 | 452 |
| child after parent COW | 228 | 123 | 20 | 208 |
| after unmap | 128 | 128 | 128 | 0 |

The `file_shared_touched` stage now shares physical frames between the private clean mapping and the shared mapping. Forked private mappings remain read-only until first write; COW copies then increase each task's unique set and reduce mapcount-shared pages.

## Build and evidence identity

- T490 host: Ubuntu 26.04.1 / Linux `7.0.0-43-generic` / x86_64; QEMU 10.2.1.
- Guest: AArch64, pure TCG, 2 GiB, 4 vCPUs, virtio GPU/input/block/network; static platform gate 15/15 PASS.
- Isolated source tree `/home/mo/xk6/worktrees/xk-compat-fix-r1`, HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`, 57 dirty files including the candidate patches.
- Candidate kernel SHA-256 `0031ac391c397a3e6562afdd87b11bc56f79e377ee4d97618e259e5f11a4acf4`; `config_sha256=128e17a1045d6b541ebf71c0f031f4a1d879f0622e3334ea343df486dded6a83`; `build_id=9b03b5e36eb08d6edd5964fb685318a59f97412e6339833bdd5802b745914e1d`.
- Full command, console, environment, original screenshot verdicts, remote PPM hashes, and local archive checksums are in [file-private C probe r2 evidence](../evidence/2026-11-19_t490-file-private-pagecache-pss-r2/).

## Limits

This is a small standalone memory probe. It does not measure the Chromium process tree at 1 Hz, does not provide a 60-second post-load peak, and does not establish a performance before/after result. The global process/PFN scan cost has not been measured at Chromium scale. The six QEMU monitor PPMs have identical SHA-256 and show “Display output is not active”; they are archived acquisition evidence and do not prove a visible GUI or Chromium page. Chromium Mojo, inotify watcher page behavior, and full GUI/session stability regressions remain separate work.
