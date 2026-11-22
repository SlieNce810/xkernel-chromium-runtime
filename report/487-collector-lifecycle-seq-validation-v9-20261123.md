# T490 Chromium 149 lifecycle sequence 与采集器严格读取 v9（2026-11-23）

## 结果

v9 使用同一 Chromium 149.0.7827.53、2 GiB `pkg-installed.img`、AArch64 纯 TCG
和新版 preload/autorun。事件 JSON 改为把 `seq` 设置为同一
`LINUX_CLOCK_MONOTONIC` 域的 `t_ns`，避免 fork 后每个进程的静态计数器重新从1开始。

从原始 console 恢复了 14 条 lifecycle 事件，严格读取器验证通过：

```text
COLLECTOR_EVENTS_VALID 14 first_seq=44909970512 last_seq=148300089072
```

验证覆盖：

- schema 为 `xkernel.browser.lifecycle.v1`；
- 所有事件 run ID 为 `preload-exec149-v9`；
- clock ID 全部为 `LINUX_CLOCK_MONOTONIC`；
- seq 严格递增；
- event ID 唯一；
- JSON 文件可以直接交给 `scripts/collect_metrics.py` 的 `read_events()`。

## 事件范围

本轮恢复了：

- `preload_attached`；
- `browser_main_loop_ready`；
- 多个 `zygote_fork_boundary`，含 request ID 和 child PID；
- Renderer 进程实际观察；
- 页面导航请求。

本轮仍没有 `renderer_ready` 或 `first_valid_frame`。因此事件格式和采集器入口已经
通过严格读取验证，但 renderer-create、首帧和正式内存峰值指标仍保持 invalid，不能
进入 before/after 统计。

## 原始证据

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec149-v9/
```

仓库保存了原始 console、解析后的 `lifecycle-events.jsonl`、命令/环境、PPM 严格
判据 JSON 和哈希清单。原始 PPM 仍只留在 T490。
