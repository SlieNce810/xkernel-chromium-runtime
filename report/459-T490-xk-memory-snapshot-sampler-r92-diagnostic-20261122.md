# T490 R92 xk_memory_snapshot 1 Hz 前置诊断（2026-11-22）

R92 用已编译的 `/proc/<browser-pid>/xk_memory_snapshot` 做 30 次连续读取，目标是测量接口本身能否作为低开销采集源。轮次使用 2 GiB、AArch64 QEMU 纯 TCG、默认多进程 Chromium、Weston 原生 Wayland；`MP_TRACE_VALUE=0`、`MP_LEDGER_VALUE=0`，避免把旧的诊断扫描混入接口开销。

## 结果

guest 侧脚本计数为 30 次尝试、27 次 `complete=1`。串口解析器在竞争输出下观察到 29 个完整 marker block，其中 26 个完整快照、3 个因 `tree_changed` 被内核拒绝；一个 block 的 marker 在共享串口输出中丢失。解析器因此把可见样本严格记为 26/29，并把 guest 计数与串口可见计数分开保存。

| 项目 | 观测值 |
|---|---:|
| 可见读取 block | 29 |
| 可见完整快照 | 26 |
| `tree_changed` 拒绝 | 3 |
| `read_ms` 中位数 | 495 ms |
| `read_ms` P95 | 9510.2 ms |
| `read_ms` 最大值 | 14845 ms |
| begin 间隔中位数 | 1970.5 ms |
| begin 间隔 P95 | 11940.5 ms |
| 后代行数范围 | 1–8 |

完整原始 console、命令、环境、平台检查、截图判据、PPM SHA-256 和递归 artifact 清单在 [R92 evidence](../evidence/2026-11-22_t490-r92-xk-snapshot-sampler/)；`parse_xk_snapshot_samples.py` 生成 `snapshot-samples.jsonl`、`snapshot-sampler-summary.json` 和 `snapshot-sampler-index.txt`。

R92 使用的是 timing 字段加入前的 kernel，因此该轮 summary 的 `kernel_timing_ns` 为空；后续轮次会用同一接口头部补充 resident walk、mapcount 和 rollup 的 guest 时长。

## 判定

这轮证明了新接口可以在进程树变化时拒绝不一致结果，也能在树稳定时输出逐进程 RSS/PSS/USS/共享页。但它还不是正式 1 Hz 采集：读取 P95 达到 9.5 秒，且串口 marker 存在丢失/交错，begin 间隔中位数约 2 秒。R92 不写入正式 before/after CSV，也不改变当前性能 0/0 审计。

开销主要来自接口内部为 PSS/USS 建立全进程 resident frame 与 mapcount 快照；下一步应在保持共享页计量和树一致性判据的前提下，减少重复 page-table walk 或将快照构建与一次性事件导出解耦。当前候选不作为优化收益结论。

## 验证

- `bash -n`：R92 guest sampler 通过；
- `python3 -m py_compile scripts/t490/parse_xk_snapshot_samples.py`：通过；
- parser 重算 R92：29 个可见 block、26 个完整、3 个 `tree_changed`，与保存的 summary 一致；
- 原始 PPM 未提交，仓库仅保留 `ppm-sha256-all.txt`。
