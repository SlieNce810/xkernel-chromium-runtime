# T490 native Linux compatibility and procfs memory reference（2026-11-19）

## 结论

T490 网络恢复后，同一 `compatprobe.c` 在 T490 native Linux 7.0.0-43-generic / x86_64 host 运行通过：inotify/timerfd 11/11、SCM_RIGHTS stream short-read 6/6。单独的 procfs memory probe 也在该 Linux host 完成匿名页、文件私有/共享映射、触页、fork、parent/child COW 与 unmap 阶段采样，`smaps_rollup` 返回 RSS/PSS/USS 原始值。

这些结果完成了 T490 native Linux 参考侧。此报告记录时尚未运行 x-kernel AArch64 guest，也未运行 Chromium watcher 页面回归；不能把 host Linux PASS 写成 x-kernel 兼容 PASS。稍后同日的 guest 对照发现 inotify、SCM_RIGHTS 与 PSS/USS 差异，详见 [report 332](332-T490-xkernel-inotify-scm-rights-procfs-probe-r1-20261119.md)。T490 kernel source working tree 仍是 `b73e581` 加 53 个既有 dirty files；两轮均未修改该树。

## 兼容性 probe

| 依赖 | T490 native Linux 结果 |
|---|---|
| timerfd create / one-shot settime / poll / 64-bit expiration read | 4/4 PASS |
| inotify init1 / add watch / create-write / poll / read matching IN_CREATE / rm_watch | 7/7 PASS |
| SCM_RIGHTS over AF_UNIX SOCK_STREAM, fd with 100 bytes, one-byte recvmsg loop | 6/6 PASS；fd 仅随首个字节交付，后续不重复，payload 完整 |

## procfs memory probe

在 32 页的 anon、file-private、file-shared mapping 中做触页，fork 后 child 与 parent 分别触发私有 COW，同时保留 shared mapping，最后释放并 unmap。下表取自原始 `smaps_rollup` 输出，单位 kB：

| 阶段 | RSS | PSS | USS | Shared |
|---|---:|---:|---:|---:|
| baseline | 2020 | 136 | 120 | 1900 |
| anon touched | 2148 | 264 | 248 | 1900 |
| file-private touched | 2276 | 392 | 376 | 1900 |
| file-shared touched | 2404 | 392 | 248 | 2156 |
| fork child after child COW | 564 | 141 | 36 | 528 |
| parent before own COW | 2404 | 290 | 48 | 2356 |
| parent after own COW | 2404 | 294 | 56 | 2348 |
| child after parent COW | 564 | 143 | 40 | 524 |
| parent after unmap | 2020 | 136 | 120 | 1900 |

这组原始值证明 T490 host Linux 的 procfs 可提供 smaps_rollup RSS/PSS/USS，并能观察 shared/COW/fork/unmap 阶段变化。它是 standalone host probe，不是 x-kernel `/proc` 兼容验证，也不是 Chromium tree 的 1 Hz/60 秒性能样本。

## 复现证据

完整命令、环境、三份 stdout 与 SHA-256 在 [T490 native Linux reference r1](../evidence/2026-11-19_t490-native-linux-reference-r1/)。后续 guest 输出及 frozen-kernel/source 哈希见 [compat-memory guest r1](../evidence/2026-11-19_t490-acceptance-compat-memory-r1/)。下一步需先隔离 dirty kernel snapshot 并修复已定位差异，再以同源探针和 Chromium watcher/Mojo 回归验证。

更新 parser 的 native Linux 复跑见 [report 336](336-T490-native-Linux-procfs-memory-parser-r2-20261119.md) 和 [procfs r2 evidence](../evidence/2026-11-19_t490-native-linux-procfs-r2/)。同日之后的 x-kernel mapcount PSS/USS 候选值及与 Linux 的 MAP_PRIVATE/shared-file 偏差见 [report 337](337-x-kernel-PSS-USS候选采样与MAP_PRIVATE差异-20261119.md)。
