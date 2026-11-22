# T490 procfs 进程树端点优先 sampler v5（2026-11-23）

## 目的

在 v2/v3 轮中，原 sampler 先遍历全部 `/proc/*/stat`，再读取
`tree_smaps_rollup`/`smaps_rollup`；Chromium 启动早期会把该路径卡在 procfs 读取，
导致 sampler 没有状态文件和导出。v5 对 `scripts/t490/proc_tree_sampler.c` 做了
单变量改动：

- 首选 `/proc/<browser>/xk_memory_snapshot`，解析一次性进程树、RSS/PSS/USS 和
  generation/timing；
- 若端点不存在，尝试已有 `/proc/<browser>/tree_smaps_rollup`；
- 两个端点都缺失时保留原逐进程回退路径；
- 端点路径产生的 process-started/exited 事件与 CSV 使用同一 process instance，
  不把缺失数值填零。

本次 AArch64 交叉编译成功，构建产物仅用于该诊断轮，未宣称优化收益。

## 固定运行条件与结果

T490 `10.249.11.192`、AArch64 QEMU 纯 TCG、2 GiB、4 vCPU、Weston 原生 Wayland、
Chromium 149.0.7827.53、默认多进程参数。v5 命令使用 180 秒内存 sampler、
生命周期 preload、单次重载和 420 秒会话窗口。

日志中的 procfs 访问显示当前实际运行内核 `51c4028594e4aff9fc5b9964c4294a2904621c93e84093ac711858c454aed284`
没有这两个 bulk 端点：

```text
/proc/72/xk_memory_snapshot  -> NotFound
/proc/72/tree_smaps_rollup   -> NotFound
```

因此 sampler 回退到原路径；会话结束前没有：

- `PROC_TREE_SAMPLER_RESULT`；
- `MP_PERF_MEMORY_EXPORT_BEGIN/END`；
- `memory-samples.csv`；
- `proc-tree-sampler.status`。

本轮 Chromium RSS/PSS/USS 有效样本仍为 0。Renderer 观察器独立工作并记录了 PID
418、PPID 241 及与 Zygote request 的关联，但这不能替代内存指标或首帧判据。

v4 是同一改动的先行轮，证据保存在
[v4 evidence](../evidence/2026-11-23_t490-sampler-endpoint-v4/)。v4 还暴露了串口
导出器在重复周期中再次输出同一 `event_id`；严格提取器因此拒绝该文件。v5 也
保留了同类重复事件，提取器明确报出：

```text
LIFECYCLE_INVALID: duplicate event_id sampler-direct-v5:162:60555232832:1
```

这属于证据完整性失败，不把重复行去重后伪装成有效生命周期样本。

## 判定

本轮没有测得性能收益，端点优先代码保留为待内核端点配套的实验改动，不进入最终
优化结论。当前内核需要先接入并重新构建 procfs bulk snapshot（已有历史 patch
`report/patches/0020-procfs-xk-memory-snapshot-mvp.patch`，但它与 T490 当前 dirty
源码上下文不直接匹配，未在本轮强行套用）。在端点存在且能完成启动后 60 秒窗口
前，四项正式指标继续为 `0/4`，before/after 为 `0/0`。

## 证据与复核

- [v5 evidence](../evidence/2026-11-23_t490-sampler-direct-v5/)：console、命令、
  环境、平台检查、生命周期/稳定性材料和截图判据；原始 PPM 仍只保留在 T490；
- [v4 evidence](../evidence/2026-11-23_t490-sampler-endpoint-v4/)：同一候选的先行
  轮和重复 event ID 失败材料；
- `aarch64-linux-musl-gcc -static -O2 -Wall -Wextra` 编译 `proc_tree_sampler.c`：
  通过；
- `bash -n scripts/t490/autorun_mp_score_observe6.sh`、生命周期提取器和现有
  collector 单元测试：通过；
- 采集器保持失败关闭：没有把缺失内存值转成零或部分样本。
