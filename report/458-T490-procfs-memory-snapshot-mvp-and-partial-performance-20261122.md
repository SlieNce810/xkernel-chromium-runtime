# T490 procfs 内存快照 MVP 与部分性能数据（2026-11-22）

本轮把进程树内存采集从反复读取多个 `/proc/<pid>/smaps_rollup` 的诊断路径，推进到一个只读、带一致性校验的内核接口。接口补丁保存在 [report/patches/0020-procfs-xk-memory-snapshot-mvp.patch](patches/0020-procfs-xk-memory-snapshot-mvp.patch)，源码位置为 `fs/filesystems/procfs/src/task_nodes/root.rs`，运行时文件为 `/proc/<root-pid>/xk_memory_snapshot`。

## 接口与一致性口径

一次读取执行以下步骤：

1. 记录根进程的启动时间，并用 PID、PPID 和启动时间对当前进程树生成 FNV-1a 身份值；
2. 复用已有的 `process_smaps_rollup_snapshot()`，得到每个进程的 RSS、PSS、USS 和共享页；
3. 按根 PID 过滤后代进程，并为每行保留 PID、PPID 和启动时间；
4. 再次计算进程树身份。树发生变化、根进程退出、PID 被复用或没有有效行时，返回 `complete=0` 和原因，不把部分结果当成样本。

成功头部使用 guest 单调时钟，格式为：

```text
snapshot version=1 root_pid=... root_start=... tree_generation=... t_ns=... clock_id=monotonic complete=1 pss_uss_supported=1
```

每个进程行包含 `rss_pages`、`pss_pages`、`uss_pages` 和 `shared_pages`。根进程标为 `role=browser`，其他角色暂标为 `unknown`，后续由生命周期事件按 PID 与启动时间关联。`tree_generation` 和启动时间同时用于避免 PID 复用误关联。

## T490 复现

三轮均使用 T490（10.249.11.192）、AArch64 QEMU 纯 TCG、2 GiB、4 vCPU、Weston 原生 Wayland、默认 Browser → Zygote → Renderer 参数。构建材料记录的 kernel SHA-256 为 `84f4a3bc39b7a10918e4bc2e42394f9648f0ebcb03152d2ad40179331e74d1e9`，基础镜像 SHA-256 为 `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`。

- [R89 MVP](../evidence/2026-11-22_t490-r89-xk-snapshot-mvp/)：浏览器刚进入主循环时读取成功，`complete=1`，得到根 Browser 一行。该时刻子进程尚未全部建立，故只证明接口和根行，不作为完整进程树样本。
- [R90 延迟探针](../evidence/2026-11-22_t490-r90-xk-snapshot-delayed/)：探针脚本传输时出现换行损坏，保留原始会话材料但不作结论。
- [R91 延迟读取](../evidence/2026-11-22_t490-r91-xk-snapshot-delayed/)：等待约 300 秒后读取成功，`complete=1`，得到 7 行（Browser 加 6 个后代进程），并记录各行 RSS/PSS/USS/共享页。R91 仍是单次快照，不等同于正式 1 Hz 峰值统计。

三份目录都保留命令、环境、构建材料、平台检查、console、页面判据和 `artifact-sha256.txt`。原始 QEMU PPM 继续只保留在 T490，仓库只提交判据与哈希材料。

## 可复用读取器

`scripts/t490/xk_memory_snapshot.sh` 在 guest 中读取并校验快照，输出原始文本和 CSV：

```sh
scripts/t490/xk_memory_snapshot.sh "$BROWSER_PID" /tmp/xk-memory-snapshot.txt run-01
```

读取器检查版本、`complete=1`、非空 `snapshot-end`，并核对 `snapshot-end rows=N` 与实际进程行数；失败时不留下可误用的 CSV。

## 可计入的部分性能数据

`scripts/t490/collect_partial_perf.py` 将启动事件和严格 QMP 截图上界独立归档，不把无效的 renderer/PSS/USS 字段写入正式 before/after CSV。R81 的合并事件流和结果位于 [R81 evidence](../evidence/2026-11-22_t490-r81-perf-before-r3/)：

| 指标 | R81 结果 | 口径 |
|---|---:|---|
| Browser 启动请求 → 主循环就绪 | 34613.292224 ms | 同一 guest `LINUX_CLOCK_MONOTONIC` 事件流 |
| 首个严格 QMP 截图上界 | 360000 ms | `shot-01-at0360s.ppm`，保守 screendump 上界；相邻截图采样间隔 393300 ms |
| 原生页面首帧 | 无效 | 没有 `first_valid_frame` 事件 |
| renderer 创建延迟 | 无效 | 没有 `renderer_ready` 事件 |
| 进程树 RSS/PSS/USS 峰值 | 无效 | sampler `valid=false`，记录 212 个错误和 254 个样本 ID |

这些部分结果能复核启动和页面达到严格判据的时间，但仍不能替代四项指标各自 before/after 五轮。当前总目标仍保持 `INCOMPLETE`，正式性能有效样本仍为 0/0；本轮没有宣称优化收益。

## 本轮验证

- `bash -n scripts/t490/xk_memory_snapshot.sh`：通过；
- `python3 -m py_compile scripts/t490/collect_partial_perf.py`：通过；
- `python3 scripts/t490/collect_partial_perf.py --help`：通过；
- 用 R81 的 base/probe 两份生命周期事件、严格截图断言和 sampler extraction 重算 `partial-metrics.json`：通过，事件顺序与 run ID 校验生效；
- R91 延迟读取：`complete=1`、`rows=7`，所有数值和原始 console 可追溯。
