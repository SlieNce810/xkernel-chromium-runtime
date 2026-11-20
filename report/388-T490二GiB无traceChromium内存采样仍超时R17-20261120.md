# T490 2 GiB no-trace Chromium 进程树内存复测 R17（2026-11-20）

## 结论

R17 延长 R16 的 initial-page ready deadline 至 1200 秒，关闭 Chromium startup trace，继续使用同一 2 GiB AArch64 纯 TCG 内核、900 秒进程树 memory sampler、14 秒 family watchdog、1 次真实 Ctrl+R 和 800 秒 diagnostic hold。首页 strict 在 `463.688 s` 通过，重载 `1/1` 通过，driver `800.000 s` 保持通过；此轮进入了真实 Chromium memory sampler 窗口并成功完成串口包传输。

内存数据仍无效：`proc-tree-sampler.status` 为 `result=FAIL`、`missed=213`；extractor 得到 218 个 sample ID、1,329 行、8 个有内存行的实例，221 条错误。`sampler_overrun_ms` 186 次，中位数 `2,387 ms`、P95 `8,401 ms`、最大 `78,962 ms`；另有进程树不可用 19 次、bulk endpoint 不可用 8 次、sample incomplete 8 次。trace 关闭后仍有大量超时，说明 R15 的问题不只由 trace 文件和串口导出造成。R17 当前 kernel 仍使用 R15 的 BTreeMap PFN mapcount 实现，下一轮应以可逆的 dense PFN count 候选单独验证。

R17 没有通过 `collect_metrics.py` 的完整样本门禁：其 memory lifecycle ledger 缺少 `browser_main_loop_ready` 等统一浏览器指标事件，校验结果为 `expected one browser_main_loop_ready event, found 0`，见 `collect-metrics-validation.json`。本轮不能计入四指标 batch，也不能使用其 PSS/RSS/USS 原始 peak 作资格线结论。

证据：[evidence/2026-11-20_t490-r17-memory-only-ready1200](../evidence/2026-11-20_t490-r17-memory-only-ready1200/)。memory exporter 的 69 块 serial bundle 完整校验，但状态保持 invalid；原始 error log、CSV、lifecycle events、status、tar 与 extraction summary 均在 `memory-export/`。T490 PPM 原件留存于主机，sha 清单为 [`evidence/_ppm-sha256-r17-memory-only-ready1200.txt`](../evidence/_ppm-sha256-r17-memory-only-ready1200.txt)。

## 平台和运行配置

- QEMU `10.2.1`；AArch64 `kplat-aarch64`；`-m 2g`、4 vCPU、`cortex-a76`；纯 TCG；virtio GPU/input/block/network。
- Chromium `149.0.7827.53`；基础镜像 SHA-256 `d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`。
- 内核源码 HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`，含此前未提交工作树改动；kernel.bin SHA-256 `f988d68b3d8545875af30a931734b5936f9a13b9850df67b8fe8b074a7ccb3f1`。
- `STABILITY_TRACE_MODE=0`、`STABILITY_MEMORY_SAMPLER=1`、`STABILITY_MEMORY_SAMPLE_SECONDS=900`、`STABILITY_CAPTURE_GUEST_CLOCK_SYNC=1`、`STABILITY_READY_TIMEOUT=1200`、1 次重载、30 秒 settle、800 秒 diagnostic hold。

复现：

```bash
STABILITY_DIAGNOSTIC_ONLY=1 STABILITY_TRACE_MODE=0 STABILITY_MEMORY_SAMPLER=1 STABILITY_MEMORY_SAMPLE_SECONDS=900 STABILITY_CAPTURE_GUEST_CLOCK_SYNC=1 STABILITY_RELOAD_COUNT=1 STABILITY_RELOAD_INTERVAL=30 STABILITY_HOLD_SECONDS=800 STABILITY_READY_TIMEOUT=1200 MP_FAMILY_WATCHDOG_INTERVAL=14 MP_FAMILY_DIAGNOSTICS=1 MP_MAX_SECONDS=2100 KERNEL_DIR=/home/mo/xk6/worktrees/xk-compat-fix-r1 BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img bash scripts/t490/run_stability_round_mp.sh r17-memory-only-ready1200 2200 1200 1 30 800
```

实际稳定性状态是 `STABILITY_DRIVER_RC=0`、`STABILITY_ROUND_RC=0`、`STABILITY_NORMALIZER_RC=0`、`STABILITY_GATE_RC=78`；最后一个值是 diagnostic-only 约定，不代表正式 gate 通过。

## R15/R16/R17 对照解释

| 轮次 | trace | strict 首页/重载 | 内存 sampler | 结果 |
|---|---|---|---|---|
| R15 | startup trace 开启 | 1 次首页、1/1 重载通过 | 160 sample ID / 10 个 sampler 实例；missed 158，overrun 中位 3,035.5 ms、最大 43.23 s | 内存无效 |
| R16 | startup trace 关闭 | 700 秒内首页 timeout | sampler 未完成 900 秒窗口 | 无内存包；不能比较 trace 影响 |
| R17 | startup trace 关闭 | 463.688 秒首页 strict、1/1 重载通过 | 218 sample ID / 8 个有行实例；missed 213，overrun 中位 2,387 ms、最大 78.962 s | 内存无效 |

R16 与 R17 的页面结果不同，且两轮都只有一个 sample，不能据此声明 trace 关闭对采样性能有可靠收益。R17 仍显示真实 Chromium 下的单遍 mapcount 每秒采样超时。下一步以 R17 内核/trace-off 条件作 parent，对 dense PFN count candidate 进行单变量构建和同条件 guest 回归；R15/R17 均留作诊断对照，不纳入正式 before/after 统计。
