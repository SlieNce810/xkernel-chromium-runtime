# T490 native Linux procfs memory probe r2 (2026-11-19)

## 结论

更新后的 `procfs_memory_probe.c` 在 T490 native Linux 7.0.0-43-generic / x86_64 上编译并通过（rc 0）。它优先读取候选 x-kernel 的 `USS:` / `Shared:` 字段；在 Linux 上这些自定义字段不存在时，仍从标准 `Private_Clean/Private_Dirty` 和 `Shared_Clean/Shared_Dirty` 汇总 USS/shared 值。Linux PSS/USS 的解析兼容性通过，完整命令、环境、源码和二进制 hash 与 console 见 [native Linux procfs r2 evidence](../evidence/2026-11-19_t490-native-linux-procfs-r2/)。

## 原始阶段值

单位 kB。每阶段仍打印 statm、status、smaps_rollup 原始字段；`USS` 为 probe 对私有字段的汇总，`Shared` 为共享字段汇总。

| 阶段 | RSS | PSS | USS | Shared |
|---|---:|---:|---:|---:|
| baseline | 2024 | 139 | 124 | 1900 |
| anon touched | 2152 | 267 | 252 | 1900 |
| file-private touched | 2280 | 395 | 380 | 1900 |
| file-shared touched | 2408 | 395 | 252 | 2156 |
| child after child COW | 568 | 145 | 40 | 528 |
| parent before parent COW | 2408 | 294 | 52 | 2356 |
| parent after parent COW | 2408 | 298 | 60 | 2348 |
| child after parent COW | 568 | 147 | 44 | 524 |
| after unmap | 2024 | 139 | 124 | 1900 |

这轮是 Linux 对照和探针 parser 的复核。最初 x-kernel mapcount 版本的 `file_shared_touched` 与 Linux 分布不符，随后修正 MAP_PRIVATE 页缓存读取与 COW；修复版相同 guest C probe 的 file-shared/fork/COW/unmap 趋势已对齐，详见 [report 337](337-x-kernel-PSS-USS候选采样与MAP_PRIVATE差异-20261119.md) 和 [report 338](338-MAP_PRIVATE页缓存共享与PSS-USS-guest复测-20261119.md)。这些仍是 standalone 小进程探针，不是 Chromium 进程树 1 Hz/60 秒峰值样本。

## 与先前参考的关系

此前 T490 native Linux standalone 参考与 Linux 5.15 WSL2 结果见 [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md) 和 [report 330](330-procfs-memory-WSL2-reference-and-T490-followup-20261119.md)。r2 使用更新后的 C parser、相同页面构造逻辑，结果方向一致：触页增加 RSS/PSS/USS，文件共享映射提高 Shared，fork/COW 后父子私有集随写时复制变化，unmap 后 USS 回到 baseline，RSS high-water mark 保留峰值。
