# T490 dense PFN 候选同条件 Chromium memory sampler 重复对照 R20（2026-11-20）

## 结论

R20 在 dense PFN kernel 上按 R19 相同参数独立重跑：AArch64 2 GiB 纯 TCG、trace-off、Chromium 149、official-index、900 秒进程树采样、1200 秒首屏 deadline、1 次真实 Ctrl+R、30 秒 settle、800 秒 diagnostic hold。首页 strict elapsed `589.475 s`，重载 `1/1` 通过，800 秒保持完成；memory serial 包完整解码。

重复结果再次显示 dense candidate 的 memory sample 数和 missed/median overrun 相对 R17 BTreeMap parent 方向较好：R19/R20 各有298/304 sample IDs（R17=218），missed 为146/151（R17=213），overrun median 为1969/2130 ms（R17=2387 ms）。但三轮 sampler status 都是 `FAIL`，overrun 均值方向不代表1 Hz通过；dense 两轮的 P95（15.885/17.361 s）明显高于 R17（8.401 s），且最大值在R19达88.210 s。dense 两轮首次 strict 首页均约589.2–589.5 s，比 R17 463.688 s 慢约125.6 s。该候选呈现重复可见的 tradeoff，当前不作为最终优化。

详细 run-level 指标和错误类型存于 [`diagnostic-sampler-comparison.json`](../evidence/2026-11-20_t490-r20-dense-memory-repeat/diagnostic-sampler-comparison.json)。R19 与 R20 各为一个独立 after run，R17 仅一个 parent run；before/after 均未达到五次，且所有内存 CSV 都未通过 1 Hz/status 门禁，因此这些数字仅用于机制定位，不能作为最终性能统计。

## R20 内存状态

- `proc-tree-sampler.status`: `result=FAIL`、`samples=304`、`process_instances=11`、`missed=151`、`memory_source=procfs-tree-smaps_rollup`。
- exporter 解码：84 个串口块、1,893 CSV 行、304 个 sample ID、9 个有内存行的进程实例、160 条错误；`memory-export/extraction.json` 标记 `valid=false`。
- 误差类型：115 次 overrun、27 次 process tree unavailable、9 次 bulk endpoint unavailable、9 条 sample incomplete；overrun min/median/P95/max 为 1.517/2.130/17.361/27.152 秒。
- `collect_metrics.py` 因 memory lifecycle ledger 缺少 `browser_main_loop_ready` 而拒绝样本，具体结果见 `collect-metrics-validation.json`。

## 平台和证据

QEMU 实际参数、Chromium 镜像 SHA、runner 环境和 R20 raw console 见 [evidence/2026-11-20_t490-r20-dense-memory-repeat](../evidence/2026-11-20_t490-r20-dense-memory-repeat/)。kernel.bin SHA-256 `beaa86361cdff4a6504d16acbb565c5e598f0095fbccb81565b3a3c2c5ba436f`；候选补丁为 [`procfs-pfn-count-dense.patch`](../patches/compat/procfs-pfn-count-dense.patch)。dense PFN 的 PSS/USS/COW 小内存语义回归已在 [report 389](389-T490densePFNmapcount候选构建及PSS-COW回归R18-20261120.md) 通过。

R20 为 diagnostic-only，`STABILITY_GATE_RC=78` 表示正式 gate 跳过。六张周期 QEMU screenshot 不作为浏览器通过证据；strict 首页和重载证据来自稳定性 driver 单独保存的 `stability/load-00-initial.ppm` / `load-01-reload.ppm`，原 PPM 留在 T490，SHA-256 清单为 [`evidence/_ppm-sha256-r20-dense-memory-repeat.txt`](../evidence/_ppm-sha256-r20-dense-memory-repeat.txt)。

## 继续计划

保留 dense PFN 补丁作为可回退实验候选，不把它加入最终收益结论。下一步重点检查 `resident_page_frames()` 页表枚举与 bulk snapshot 各阶段耗时、调度长尾及跨样本进程树缺失；每个新候选仍先与 parent 做单变量语义/采样回归。四项指标、memory peak 资格线、before/after 各五次和正式 stability 30 分钟/10 reload 仍未完成。
