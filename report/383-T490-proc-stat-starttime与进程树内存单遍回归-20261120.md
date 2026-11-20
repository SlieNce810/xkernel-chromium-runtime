# T490 `/proc` 进程起始时刻修复与进程树内存单遍采样 R13（2026-11-20）

## 本轮结论

R13 是 2 GiB AArch64 纯 TCG 下的诊断探针轮，不启动 Weston 或 Chromium，不计入功能、稳定性或四指标性能验收。它确认了两项内核/工具改动可构建并在客体运行：`/proc/<pid>/stat` 第 22 字段现在为非零起始 tick；采集器可通过新的 `tree_smaps_rollup` 一次取得进程树内存数据。

原始证据位于 [evidence/2026-11-20_t490-procfs-bulk](../evidence/2026-11-20_t490-procfs-bulk/)；R13 的 QEMU 屏幕为 `Display output is not active.`，这是因为本轮只跑 shell 探针、没有启动图形会话。`ppm-summary.txt` 的 6 张截图全部严格判据失败，不能用作图形功能或稳定性通过证明。

## 缺陷、源码和补丁

### `/proc/<pid>/stat` 第 22 字段为零

采集器用 `PID-start_ticks` 作为进程实例标识，避免 PID 复用导致事件关联混淆。R2 guest 证据中 Browser PID 5 的 field 22 是 0，生成 `5-0`；这不符合 Linux `/proc/<pid>/stat` 的进程启动时间语义。

修复在 `task/ktask/src/task.rs` 为每个任务保存创建时的单调时钟纳秒值，并在 `process/kprocess/src/stat.rs` 按 Linux `USER_HZ=100` 输出到 field 22。可应用补丁为 [`proc-stat-starttime.patch`](../patches/compat/proc-stat-starttime.patch)。复现使用 `proc_tree_sampler.c` 读取 `/proc/<pid>/stat` 并形成进程实例 ID；运行脚本为 `autorun_proc_tree_sampler_smoke.sh`。

Linux 对照见 `procfs-linux-control.txt`：T490 主机 `SC_CLK_TCK=100`、field 22 为正数 `24836125`；`/proc/self/smaps_rollup` 的 RSS/PSS/Private USS 均为正数。R13 guest 的 Browser 测试根进程 `/proc/5/stat` field 22 为 `159` ticks，实例为 `5-159`；子进程 PID 11 的实例为 `11-189`。该结果与修复前的 `5-0` 区分开。

### 每个进程重复扫描全部地址空间

R12 发现采集器对进程树内的每个 PID 单独读 `smaps_rollup`，而内核每次读取都重新遍历全部进程的驻留页并重算 PFN mapcount。R12 的诊断采样每次耗时中位数 10.644 秒、最大 204.888 秒，产生 46 个采样错误，不能用于峰值统计。

新增 `/proc/<pid>/tree_smaps_rollup`：内核一次建立全进程 resident-frame/mapcount 快照，输出该 PID 及后代的 RSS/PSS/USS；采集器核对已发现 PID 与 PPID 后写出完整样本。缺少端点时才回退到逐 PID `smaps_rollup`；数据不完整或关联不符时整次样本作废。源码位于 `fs/filesystems/procfs/src/task_nodes/root.rs` 和 `scripts/t490/proc_tree_sampler.c`，补丁为 [`procfs-tree-rollup.patch`](../patches/compat/procfs-tree-rollup.patch)。它基于仓库已有的 mapcount/驻留页统计补丁，不能单独替代该统计实现。

## 构建和运行结果

T490 内核树 HEAD 为 `b73e581`，该树在本轮前已含多项未提交兼容改动；没有重置或覆盖这些改动。上述两个补丁在 T490 源码上均通过 `git apply --reverse --check`，内核构建完成，输出 SHA-256 为 `f988d68b3d8545875af30a931734b5936f9a13b9850df67b8fe8b074a7ccb3f1`。

构建命令：

```bash
make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n
```

静态采集器以 `aarch64-linux-musl-gcc -std=c11 -O2 -static -Wall -Wextra -Werror` 编译通过。追踪导出模板 dry-run、压缩/分块自检、base64 往返自检、参数注入检查和稳定性 runner dry-run 均通过，输出 `qemu_started=0`。

R13 guest smoke 的客体日志给出：

```text
PROC_TREE_SAMPLER_RESULT samples=8 processes=2 missed=0 source=procfs-tree-smaps_rollup duration_ms=7018
PROC_TREE_SMOKE sample_rows=16 processes_started=2 memory_errors=0 bad_values=0
PROC_TREE_SMOKE_PASS
```

根进程标准 `smaps_rollup` 随后读数为 RSS 560 kB、PSS 310 kB、USS 132 kB、Shared 428 kB。8 次采样共 16 行，RSS/PSS/USS 均为正数，未发现缺失字段或未完成采样。该 smoke 仅包含两个 shell 进程；7.018 秒是 8 次、1 秒间隔的完整采样窗口，不是单次采样延迟，也不是 Chromium 内存数据。

实际 QEMU 参数记录在 `cmd.txt`：AArch64 `kplat-aarch64`、`-m 2g`、4 vCPU、`cortex-a76`、纯 TCG、virtio GPU/input/block/network。客体内核为上述哈希构建物。基线镜像 SHA-256 为 `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`。

## 导出修复和验证

R12 的追踪归档存在缺失 base64 字符。trace 与 memory exporter 现于串口输出前验证 base64 长度公式、解码后与压缩文件逐字节一致及 `gzip -t`；折行同时剔除 CR/LF，并每发 16 块稍作间隔。`run_chromium_trace_probe.sh --dry-run codex-preflight-r13` 中模板注入、压缩 round-trip、块长、EOF 末块和无 QEMU dry-run 全部通过。

本地采集/汇总回归：`test_extract_perf_memory.py` 6/6、`test_extract_perf_trace.py` 14/14、`test_collect_metrics.py` 10/10、`test_compare_perf.py` 6/6。

## 限制和下一步

guest smoke 将完整 CSV 写在 `/tmp`，串口只打印汇总和 CSV 开头行；本证据包因此保留 8 次/16 行计数、首部行与状态，但没有归档全部 16 条原始 CSV 记录。下一轮会将这类 smoke 原始文件写入 guest `/root` 并通过 `pull_guest_logs.sh` 回收。本轮结果只作为实现 smoke。

本轮也不能证明 Renderer 子进程树在真实 Chromium 负载下连续 1 Hz 采样成功，也没有采集 Browser 启动、首帧或 Renderer 创建事件。四指标有效 before/after 样本仍为 0/0；还需在 Chromium 启动、实际页面导航和 60 秒保持窗口中复验该采集器，并完成每组至少五次独立冷启动。R13 也没有满足三次冷启动、30 分钟保持、十次加载或 2 GiB 六项功能回归条件。
