# T490 R101 lifecycle periodic export仍未导出（2026-11-22）

R101 把 lifecycle exporter 提前到 guest loop 的第 60 秒触发，尝试避开 R100 只在 cleanup 阶段调用导致的丢失。preload 入口仍然通过，Renderer 候选在 `MP_RENDERER_PIDS` 中出现，但 exporter 没有生成任何 `XK_LIFECYCLE_EXPORT_BEGIN/END` marker；console 的 loop 进度在早期阶段停止，QEMU 最终按固定时长结束。

本轮没有可恢复的 `renderer_ready`、`browser_main_loop_ready` 或 `first_valid_frame` JSON。进程枚举仍只作诊断，不代替生命周期事件。R101 保留命令、环境、原始 console、失败说明、PPM SHA-256 和 artifact 清单在 [R101 evidence](../evidence/2026-11-22_t490-r101-lifecycle-periodic/)。

## 判定

R100/R101 共同说明当前 preload 运行路径在 TCG Browser 启动长尾期间无法可靠完成 lifecycle 文件导出；这仍是 renderer/首帧正式指标的阻断项。两轮均不进入正式 before/after CSV，也不改变性能 0/0。后续需要先缩小 preload 对 Browser loop 的影响或改成独立、无需等待 Browser cleanup 的事件出口，再继续性能统计。
