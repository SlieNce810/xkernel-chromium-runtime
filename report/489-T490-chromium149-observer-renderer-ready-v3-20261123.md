# T490 Chromium 149 进程树观察 Renderer ready v3（2026-11-23）

## 轮次条件

v3 在 v2 的 preload 注入条件上增加一个诊断连接：当独立的 stat-only
`Browser → Zygote → Renderer` 进程树扫描首次观察到 Renderer child 时，读取同一
guest 的 lifecycle probe 文件，按 child PID 关联最近的 `zygote_fork_boundary`，并
追加两个带 guest 单调时钟的事件：

- `renderer_create_requested`，来源 `observer-zygote-fork-boundary`；
- `renderer_ready`，来源 `observer-process-tree`。

这两个事件的来源字段是刻意保留的诊断标记。它们用于把真实 PID、PPID、进程实例、
导航编号和 request ID 连起来，不能替代 Chromium 内部连接确认或页面首帧。

固定平台为 T490 `10.249.11.192`、AArch64 QEMU 纯 TCG、2 GiB、4 vCPU、Weston
原生 Wayland、镜像内 Chromium 149.0.7827.53、默认 Browser → Zygote → Renderer
路径，保留 `--js-flags=--jitless` 和 `--ipc-connection-timeout=600`。命令、环境、
内核/镜像/页面哈希在证据目录保存。

## Renderer 事件链

严格提取器从串口恢复 16 条事件：

```text
LIFECYCLE_VALID run=preload-observer-v3 events=16
first_seq=43972681728 last_seq=188462859200
export_sequence_contiguous=true
```

关键关联如下：

| 事件 | 结果 |
|---|---|
| `zygote_fork_boundary` | request `preload-observer-v3:z226:105493883664:1`，child PID `406` |
| `renderer_create_requested` | 同一 request ID、navigation `nav-00`、child PID `406`，来源 `observer-zygote-fork-boundary` |
| `renderer_ready` | PID `406`、PPID `226`、process instance `406-0`，同一 request/navigation，来源 `observer-process-tree` |
| `first_valid_frame` | 缺失 |

`renderer_ready` 的 guest 时间为 `188462859200` ns；关联 fork 边界为
`105493883664` ns。该差值只能作为“进程树观察到 child 后的诊断时间分解”，不能
作为正式 Browser 创建请求到连接确认的性能指标，因为 create 事件由观察器补写。

## 页面与内存门禁

本轮稳定性 driver 的初始严格页面门禁仍超时，未产生 `first_valid_frame`。浏览器
和 Renderer 候选均被观察到，但页面严格判据没有通过，因此不生成首帧事件。

内存 sampler 启动记录为：

```text
MP_PERF_MEMORY_SAMPLER_STARTED pid=81 run_id=preload-observer-v3 duration=180
```

会话结束前没有 `MP_PERF_MEMORY_EXPORT_BEGIN/END`、`memory-samples.csv` 或
`proc-tree-sampler.status`。本轮 RSS/PSS/USS 有效样本为 0；不把进程观察或 host
QEMU RSS 写入 Chromium 峰值内存指标。

## 证据与复核

- [v3 evidence](../evidence/2026-11-23_t490-preload-observer-v3/)：完整 console、
  16 条生命周期事件、提取 summary、稳定性事件、命令、平台检查、截图判据和哈希
  材料；原始 PPM 仍只保留在 T490；
- [observer source](../scripts/t490/autorun_mp_score_observe6.sh)：观察事件只在
  preload 开启时运行，并对同一文件使用追加写入；导出仍沿用长度/序号/哈希流程；
- `bash -n scripts/t490/autorun_mp_score_observe6.sh`：通过；
- `python3 scripts/t490/extract_lifecycle_probe_events.py ...`：16/16 事件通过
  schema、run、clock、seq、event ID 和时间顺序校验；
- 现有 `collect_metrics.py` 仍会拒绝本轮，因为缺少真实 `first_valid_frame`、完整
  `process_started` 生命周期和内存采样。这是预期的安全结果。

## 结论

v3 关闭了“Renderer PID 无法和 Zygote request 关联”的诊断缺口，证明 guest 进程树
观察可以稳定补齐关联字段。它没有关闭正式性能门禁：首帧和 Chromium 进程树
RSS/PSS/USS 仍无有效数据，四项指标保持 `0/4`，before/after 保持 `0/0`，稳定性
保持诊断 FAIL，总目标仍为 `INCOMPLETE`。
