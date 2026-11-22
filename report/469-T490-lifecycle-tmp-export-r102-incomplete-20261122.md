# T490 R102 lifecycle `/tmp` 路径对照仍未完成（2026-11-22）

R102 将 lifecycle preload 的 event path 从 `/root/lifecycle-probe-events.jsonl` 改为 `/tmp/lifecycle-probe-events.jsonl`，并把周期 exporter 同步改为读取 `/tmp`。这是针对 R100/R101 的单变量路径对照。

结果仍没有 `XK_LIFECYCLE_EXPORT_BEGIN/END`、`browser_main_loop_ready`、`navigation_requested` 或 `renderer_ready` 事件。console 的 guest loop 只推进到早期阶段，QEMU 在固定时长结束；Renderer 候选仍只来自 `MP_RENDERER_PIDS` 进程枚举。

R102 说明生命周期 preload 的重复阻断不由 `/root` 持久路径单独造成，可能位于 preload hook 与 Browser/guest loop 的交互。证据保存在 [R102 evidence](../evidence/2026-11-22_t490-r102-lifecycle-tmp/)，本轮不进入正式性能指标，也不把进程枚举当作 `renderer_ready`。
