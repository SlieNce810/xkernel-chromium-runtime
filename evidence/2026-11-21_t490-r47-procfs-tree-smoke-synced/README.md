# R47：仓库版 procfs smoke 与 process starttime 缺陷

R47 在隔离 runner 中使用仓库当前版本的 `autorun_proc_tree_sampler_smoke.sh` 和 `proc_tree_sampler.c`；输入脚本 SHA 与仓库文件一致。2 GiB AArch64 pure TCG guest 可通过 `tree_smaps_rollup` endpoint 产生 8 个样本、16 行 RSS/PSS/USS、0 missed，sampler status 为 `PASS`。但是更严格的 guest 判据输出 `bad_start_times=2` 和 `PROC_TREE_SMOKE_FAIL output validation`：CSV 与生命周期事件中的两项进程身份分别是 `5-0`、`11-0`。

原始 `/proc/5/stat` 由 guest 串口记录；按 `)` 后第 20 个 token（Linux field 22）解析结果为 0。严格提取器也以 `guest smoke summary reports ... zero start ticks` 拒绝整轮，因此这些计数不构成可用内存样本。原始 CSV 和事件文本保留在未修改的 `console.log`，没有生成或标记有效的 `memory-samples.csv`。根因与修复补丁见 [report/419](../../report/419-T490R47冻结procfs候选身份复核发现stat22为零-20261121.md)；已有补丁索引为 [`proc-stat-starttime.patch`](../../patches/compat/proc-stat-starttime.patch)。

七项 `test_extract_proc_tree_smoke` 回归通过，其中包含拒绝零起始 tick 的判据；它们确认提取器会拒绝本轮，而不证明内核缺陷已修复。QEMU 图形输出为 `Display output is not active.`，截图 640×480，不计图形、Chromium、稳定性或性能验收。

下一轮必须从冻结快照应用 `proc-stat-starttime.patch` 及 procfs 内存补丁后重新构建，并在相同 2 GiB 条件复跑；只有 root 和 child 的 field 22 均非零、原始 CSV/events 完整、提取器成功，才可把这条 smoke 记为通过。
