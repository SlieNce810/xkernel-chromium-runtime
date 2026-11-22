# T490 Chromium 149 preload `prctl` 生命周期诊断 v2（2026-11-23）

## 目的与固定条件

本轮针对 v1 的两个阻断分别做单变量复核：

1. 在 `lifecycle_event_preload.c` 中增加 `prctl(PR_SET_NAME)` 观察点，覆盖
   zygote 子进程原地改名为 `CrRendererMain`、没有再次 `execve` 的路径；
2. 同步当前 `run_stability_round_mp.sh`，确保 `lifecycle_event_preload.c` 和
   `proc_tree_sampler.c` 都真正注入 guest。

轮次使用 T490 `10.249.11.192`、AArch64 QEMU 纯 TCG、2 GiB、4 vCPU、Weston
原生 Wayland、默认 Browser → Zygote → Renderer 参数，镜像内 Chromium
149.0.7827.53。启动参数保留 `--js-flags=--jitless`、`--ipc-connection-timeout=600`
和已有图形/输入参数。内核与镜像指纹记录在证据目录的 `build-manifest.txt`：

```text
kernel SHA-256  51c4028594e4aff9fc5b9964c4294a2904621c93e84093ac711858c454aed284
image SHA-256   bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1
Chromium SHA-256 d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641
```

命令为：

```text
STABILITY_DIAGNOSTIC_ONLY=1 STABILITY_READY_TIMEOUT=180 \
STABILITY_RELOAD_WINDOW=60 STABILITY_RELOAD_SETTLE_SECONDS=5 \
STABILITY_MEMORY_SAMPLER=1 STABILITY_MEMORY_SAMPLE_SECONDS=180 \
STABILITY_LIFECYCLE_PRELOAD=1 STABILITY_PROCESS_SAMPLE_SECONDS=5 \
MP_FAMILY_WATCHDOG_INTERVAL=10 \
bash scripts/t490/run_stability_round_mp.sh preload-prctl-v2 420 30 1 30 0
```

这是诊断轮：首屏门禁超时，未计入 30 分钟/十次加载稳定性，也不进入正式
before/after 性能统计。

## 生命周期结果

从串口恢复的 14 条 probe 事件经过严格提取器验证：

```text
LIFECYCLE_VALID run=preload-prctl-v2 events=14
first_seq=46706891552 last_seq=162574029888
export_sequence_contiguous=true
```

事件包含：

- 7 条 `preload_attached`（Browser、Zygote 及其子进程）；
- 1 条 `browser_main_loop_ready`；
- 5 条带 request ID 和 child PID 的 `zygote_fork_boundary`；
- 1 条 `navigation_requested`，对应 `file:///usr/share/html-test/index.html`。

本轮仍没有 `renderer_ready` 或 `first_valid_frame`。外部进程观察在日志中记录了
Renderer 候选出现，但没有与 preload 事件配对，因此没有把它提升为 Renderer ready
证据。新增的 `prctl` wrapper 在本机 native smoke 中通过，但 T490 Chromium 路径
没有经过可拦截的 libc `prctl` 符号（该路径可能直接使用 syscall 或其他命名机制），
所以它不能单独关闭 Renderer 生命周期缺口。

## 内存采样结果

本轮确认 `LIFECYCLE_PRELOAD=/lifecycle_event_preload.so` 已注入，且日志出现：

```text
MP_PERF_MEMORY_SAMPLER_STARTED pid=81 run_id=preload-prctl-v2 duration=180
```

但在 QEMU 会话结束前没有 `MP_PERF_MEMORY_EXPORT_BEGIN/END`，也没有可恢复的
`memory-samples.csv` 或 `proc-tree-sampler.status`。因此本轮内存样本为 0，不能
作为 RSS/PSS/USS 指标。该结果保留为采样器在 Chromium 启动早期的失败证据，不补造
数值。

## 证据与复核

- [v2 evidence](../evidence/2026-11-23_t490-preload-prctl-v2/)：命令、环境、平台检查、
  完整 console、生命周期事件、提取 summary、稳定性事件及截图判据；原始 PPM 仍只
  保留在 T490，仓库目录不含 PPM；
- [lifecycle extraction tool](../scripts/t490/extract_lifecycle_probe_events.py)：同一
  工具复核本轮 14 条事件；
- `python3 -m unittest scripts/tests/test_extract_lifecycle_probe_events.py
  scripts/tests/test_collect_metrics.py`：已通过；
- `bash scripts/t490/test_lifecycle_preload_native.sh`：通过，确认新增 wrapper
  不破坏 epoll/poll/ppoll、fork 和 exec smoke。

## 结论

v2 关闭了“脚本没有注入 preload”的配置错误，证明 Browser、Zygote、导航事件在
同一 guest 单调时钟和连续导出序列下可复核；但 Renderer ready、真实首帧和 Chromium
进程树 RSS/PSS/USS 仍未形成有效样本。正式四项性能指标继续为 `0/4`，before/after
继续为 `0/0`，总体目标保持 `INCOMPLETE`。
