# inotify / timerfd WSL2 Linux 基线与 T490 对照待补（2026-11-19）

## 结论

新增的 focused `compatprobe.c --inotify-timerfd` 在 WSL2 Linux 5.15.167.4 / x86_64 上通过 11/11 个基础行为检查：timerfd 的 create、50 ms one-shot settime、poll 可读和 8-byte expiration read；inotify 的 init1、目录 watch、文件 create/write、poll、匹配 `IN_CREATE` 事件读取和 rm_watch。命令、compiler/source hash 与完整 stdout 见 [evidence/2026-11-19_wsl2-inotify-timerfd-baseline-r1](../evidence/2026-11-19_wsl2-inotify-timerfd-baseline-r1/)。

WSL2 与 T490 native Linux 7.0.0-43 均以同源 probe 通过 11/11，详见 [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md)。原 2 GiB AArch64 x-kernel guest 中 watched-directory create 没有产生可 poll 的事件；隔离候选补丁增加 parent-directory named `IN_CREATE` 及变长 inotify 记录后，同一 probe 通过 11/11。Chromium watcher 页面回归仍待完成。失败与源码定位见 [report 332](332-T490-xkernel-inotify-scm-rights-procfs-probe-r1-20261119.md)，修复版 guest 证据见 [report 335](335-inotify命名创建事件guest回归与PSS缺口-20261119.md)。

## 复现与结果

```bash
gcc -O2 -Wall -Wextra -Werror -o tmp/compatprobe-linux scripts/t490/compatprobe.c
tmp/compatprobe-linux --inotify-timerfd
```

| 子系统 | 检查 | Linux 结果 |
|---|---|---|
| timerfd | `timerfd_create(CLOCK_MONOTONIC)` | PASS |
| timerfd | `timerfd_settime` one-shot 50 ms | PASS |
| timerfd | `poll` 收到可读 | PASS |
| timerfd | 读取 64-bit expiration count | PASS |
| inotify | `inotify_init1(CLOEXEC|NONBLOCK)` | PASS |
| inotify | `inotify_add_watch(IN_CREATE|IN_CLOSE_WRITE)` | PASS |
| inotify | create/write watched file | PASS |
| inotify | `poll` 等待事件 | PASS |
| inotify | read 并按 watch descriptor/name 匹配 `IN_CREATE` | PASS |
| inotify | `inotify_rm_watch` | PASS |

focused probe 总计 11 PASS / 0 FAIL。另试跑了 compatprobe 的完整旧用例：WSL2 Linux 返回 `ENOMEM` 于跨 `madvise` hole 的范围，和该 probe 注释中的“Linux tolerates gap”期望不同；该项依赖 Linux 版本与具体 ABI 口径，不能以 WSL2 结果判作 x-kernel 缺陷。完整日志保存在 `evidence/2026-11-19_wsl2-inotify-timerfd-baseline-r1/compatprobe-full-wsl.log`。

## 后续 T490 对照命令

T490 恢复后先在 host Linux 与 x-kernel guest 上运行同一个 source/hash，再执行 Chromium watcher 页回归：

```bash
cd ~/xk6
gcc -O2 -Wall -Wextra -Werror -o /tmp/compatprobe-linux scripts/t490/compatprobe.c
/tmp/compatprobe-linux --inotify-timerfd
BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img \
  bash scripts/t490/t490_round.sh compat-inotify-timerfd-r1 300 60 \
  autorun_inotify_timerfd.sh compatprobe.c
```

后一条仍需依赖 T490 上的冻结 kernel hash、probe/build manifest 与正式证据目录完成后才能关闭兼容性矩阵条目。
