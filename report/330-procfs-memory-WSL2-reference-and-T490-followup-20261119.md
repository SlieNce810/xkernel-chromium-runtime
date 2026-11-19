# procfs 内存 WSL2 Linux 参考与 T490 follow-up（2026-11-19）

## 结论

`procfs_memory_probe.c` 在 WSL2 Linux 5.15.167.4 / x86_64 上完成了匿名页、文件私有映射、文件共享映射、触页、fork、双侧 COW 和 unmap 阶段采样。Linux `/proc/<pid>/smaps_rollup` 输出 RSS、PSS、Shared、Private 字段；probe 对缺失字段打印 `UNAVAILABLE`，不补造数值。

这是 procfs ABI 的 WSL2 Linux 单进程参考。随后同源 probe 已在 T490 native Linux 7.0.0-43 上运行，原始结果见 [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md)。2026-11-19 的 AArch64 x-kernel guest 对照能观察 statm/VmRSS 的触页和 unmap 变化，但没有 `/proc/<pid>/smaps_rollup`，PSS/USS 均不可用；共享页和 COW 归属也未充分证明。原始 guest 对照见 [report 332](332-T490-xkernel-inotify-scm-rights-procfs-probe-r1-20261119.md)。三者均不是 Chromium 进程树 1 Hz 采样或 60 秒峰值内存数据。

## 关键原始值（kB）

| 阶段 | smaps RSS | PSS | USS | Shared |
|---|---:|---:|---:|---:|
| baseline | 1816 | 187 | 116 | 1700 |
| anon touched | 1944 | 315 | 244 | 1700 |
| file-private touched | 2072 | 443 | 372 | 1700 |
| file-shared touched | 2200 | 443 | 244 | 1956 |
| parent after fork, before own COW | 2200 | 346 | 52 | 2148 |
| parent after COW | 2200 | 350 | 60 | 2140 |
| child while alive | 372 | 150 | 48 | 324 |
| parent after unmap | 1816 | 187 | 116 | 1700 |

同一输出里 `/proc/statm` 与 `VmRSS` 在 anon/file-private touch 的早期阶段没有同步显示 smaps 的 +128 kB 变化，至 file-shared 阶段才明显跳动。该 WSL2 Linux 数据说明本机 status/statm 读数适合原样保存但不能替代 PSS/USS；在 T490 host 和 x-kernel guest 上仍需用相同 probe 对照源码实现和冻结 hash。

## 复现与证据

```bash
gcc -std=gnu11 -O2 -Wall -Wextra -Werror \
  -o tmp/procfs-memory-probe scripts/t490/procfs_memory_probe.c
tmp/procfs-memory-probe
```

命令、环境、原始输出与 SHA-256 见 [WSL2 memory baseline r1](../evidence/2026-11-19_wsl2-procfs-memory-reference-r1/)。探针目前的输出是阶段性快照，不构成 `collect_metrics.py` 的 Chromium 树样本，也未观察到真实页面加载完成后 60 秒的峰值。
