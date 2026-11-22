# R46：冻结快照加 procfs 进程树内存补丁 smoke

## 结论

R46 在隔离内核 worktree 中重建冻结快照，并依次应用驻留页遍历、进程树 `smaps_rollup`、dense PFN mapcount 和直接 PTE 访问四个补丁。AArch64 内核构建通过，QEMU 2 GiB pure TCG 会话中 guest 自报 `PROC_TREE_SMOKE_PASS`：8 次采样、16 行、2 个 shell 进程、0 missed、0 缺失内存字段、0 非正数值。

本轮不能成为完整的可复核 CSV 证据：T490 上被调用的旧版 smoke autorun 没有输出 `PROC_TREE_SMOKE_MEMORY_CSV_BEGIN`、`PROC_TREE_SMOKE_EVENTS_BEGIN` 标记，串口日志也未包含完整 CSV/生命周期块。仓库提取器因此正确拒绝原始日志（`malformed smoke summary line`）；没有把摘要计数伪装成原始样本。仓库版本和 T490 版本脚本哈希不一致，已在 `script-version-check.txt` 记录。下一轮需先将仓库脚本同步到隔离的 runner 副本，再复跑。

QEMU 画面是 `Display output is not active.`；PPM 为 640×480、尺寸门禁失败。本轮没有 Weston/Chromium 图形验收，不计入冷启动、功能、稳定性或性能指标。原始 PPM 只保存在 T490，哈希见 [`evidence/_ppm-sha256-r46-procfs-tree-smoke.txt`](../_ppm-sha256-r46-procfs-tree-smoke.txt)；PNG 仅供查看。

## 可复核结果

- 冻结源 commit：`b73e5814087c9d33c5f0a35b66cc56be689d3dee`。
- 冻结跟踪改动包 SHA-256：`b3a4d5edd9aee8901ea17281f715c6832b6b323cf9711c56c16742caa7c0dea7`，与 baseline freeze r3 一致。
- 冻结 `.config` SHA-256：`42e8d16450352712d78813b5f78b7ca221dfb88fadc796f57ecf317d7e33f669`。
- AArch64 kernel ELF SHA-256：`8209d80083e8eaabc227e29edb425c51e8198f8baea4cbde89d1d539d69b3054`；实跑 `kernel.bin` SHA-256：`ccf9f066b878b8f60c35c393efb1cc3c1be5e41eef8f0d58f4903ba8846e4ada`。
- 输入 rootfs `/home/mo/x-kernel/images/pkg-installed.img` SHA-256：`bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`；本轮注入后磁盘 SHA-256：`c9197a8fdeebbf458732192d9d17a47540b35df72e643c28aa7d2e300c683265`。
- 平台：T490、QEMU 10.2.1、AArch64、2 GiB、4 vCPU、Cortex-A76、pure TCG；平台断言 15/15。
- 构建命令：`make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`。首次尝试因新 worktree 未带 ignored `.config` 退出；从冻结根复制同哈希配置后构建成功，用时 2 分 28 秒。完整记录在 `build.log`、`build.env` 和 `build-manifest.txt`。
- guest smoke 摘要原文在 `console.log`；完整 CSV/事件提取未通过，不能计算有效内存峰值。

## 复现

在 T490 Linux 运行仓库脚本时，先核对 `source-provenance.txt` 中冻结 diff 与四个补丁的顺序，然后构建隔离候选。重新运行前必须把仓库版 `autorun_proc_tree_sampler_smoke.sh`、`proc_tree_sampler.c` 及 runner helper 同步至隔离 runner，并核对 SHA-256；若串口中缺任一 CSV/事件标记，提取器必须拒绝该轮。
