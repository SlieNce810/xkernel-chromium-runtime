# T490 R94 RSS-only 快照候选拒绝（2026-11-22）

R94 测试了一个单变量候选：新增 `/proc/<browser-pid>/xk_memory_rss_snapshot`，只调用 `MmMemoryUsage::memory_usage()`，输出 RSS/shared，头部明确 `pss_uss_supported=0 rss_only=1`，并保留树 generation、PID 启动时间和 `complete=0` 拒绝语义。该 kernel SHA-256 为 `188dcc92149c61d2ee1eb16975e8bab7a187fbc59e51fb2e872009ed3975b7ec`。

## 结果

guest 尝试 30 次并报告 29 次完整；共享串口解析到 29 个 block、28 个完整、1 个 `tree_changed` 拒绝。解析得到：

| 项目 | 中位数 | P95 | 最大值 |
|---|---:|---:|---:|
| 读取总耗时 | 1242 ms | 11335.6 ms | 13727 ms |
| RSS-only `memory_walk_ns` | 391.421904 ms | 2749.733950 ms | 3015.050464 ms |
| begin 间隔 | 2957.5 ms | 13523.75 ms | 15422 ms |
| 进程树行数 | 1–8 | — | — |

原始会话、RSS 行、解析 JSONL、命令和哈希清单在 [R94 evidence](../evidence/2026-11-22_t490-r94-xk-rss-snapshot/)。

## 判定

该候选没有改善采样周期：R93 的完整 RSS/PSS/USS 快照 resident walk 中位数约 44 ms，而 R94 RSS-only 的 `memory_usage()` 遍历中位数约 391 ms；总读取 P95 也更差。候选保留为机制对照，不进入最终版本，不写入正式 before/after CSV，也不改变性能 0/0 审计。

这说明主要开销来自地址空间页表/驻留遍历本身；删去 mapcount 和 PSS/USS 计算仍不足以达到 1 Hz。后续优化应围绕 resident-page cache 或一次性快照导出设计，不能只把字段减少后当作低开销路径。

## 验证

- 新增 RSS-only 源码与 R94 kernel：`make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n` 通过；
- `parse_xk_snapshot_samples.py --prefix XK_MEMORY_RSS_SNAPSHOT`：29 block、28 完整、1 `tree_changed`；
- 原始 PPM 未提交，仅保留 `ppm-sha256-all.txt`；
- 候选未宣称为性能收益。
