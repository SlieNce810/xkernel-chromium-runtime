# T490 R93 xk_memory_snapshot 内核计时诊断（2026-11-22）

R93 在 R92 的接口上加入成功快照头部计时字段：`resident_walk_ns`、`mapcount_ns`、`rollup_ns`、`process_count` 和 `resident_pages`。本轮重新编译 kernel，SHA-256 为 `ebcfdd6f182717b47db26161f33c7e68891fc0cf83ab81d4ddb8a90a3277989f`；基础镜像仍为 `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`。

## 采集结果

R93 使用 2 GiB、AArch64 QEMU 纯 TCG、默认多进程 Chromium，关闭旧的 trace 和 ledger，尝试 20 次。guest 计数为 20 次、19 次完整；串口解析也得到 20 个 block、19 个完整、1 个 `tree_changed` 拒绝。

| 字段 | 中位数 | P95 | 最大值 |
|---|---:|---:|---:|
| 读取总耗时 | 519 ms | 843.65 ms | 1027 ms |
| resident page walk | 44.155392 ms | 146.912200 ms | 161.830960 ms |
| mapcount | 8.539152 ms | 25.843842 ms | 66.213104 ms |
| rollup 计算 | 0.754032 ms | 1.367278 ms | 1.989776 ms |
| marker begin 间隔 | 2121 ms | 2630.6 ms | 2879 ms |

完整样本的 `process_count` 从 8 增长到 12，`resident_pages` 从 5,170 增长到 49,234；原始头部、逐行进程值、解析 JSONL 和哈希清单位于 [R93 evidence](../evidence/2026-11-22_t490-r93-xk-snapshot-timing/)。

## 结论与后续

在当前样本范围内，resident page walk 是快照开销的主要部分，rollup 格式化不是热点。读取总耗时已比 R92 的长尾稳定，但固定 `sleep 1` 加读取耗时使 begin 间隔约 2.1 秒，仍不符合正式 1 Hz 口径；R93 只作机制诊断，不写入 before/after 性能 CSV。

下一项候选优化应减少 resident page-table walk 的重复工作，或把一次一致性快照缓存到 1 Hz 采集周期中，同时保留树 generation、PID 启动时间和失败即缺失的判据。当前正式四指标仍为 0/0，尚未形成优化收益结论。

## 验证

- 远端 `make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`：通过；
- 新 patch 在 T490 当前源码上 `git apply --check --reverse`：通过；
- `python3 scripts/t490/parse_xk_snapshot_samples.py` 重算 R93：20 block、19 完整、1 `tree_changed`；
- `python3 -m py_compile scripts/t490/parse_xk_snapshot_samples.py`：通过；
- 原始 PPM 未提交，只保留 `ppm-sha256-all.txt`。
