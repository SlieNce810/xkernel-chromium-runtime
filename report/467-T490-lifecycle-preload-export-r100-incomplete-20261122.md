# T490 R100 lifecycle preload export未完成（2026-11-22）

R100 启用了 `/lifecycle_event_preload.so` 和默认多进程 Chromium，关闭旧 memory sampler/ledger，使用新增的 lifecycle 压缩串口导出函数。入口校验、preload 注入和 QEMU 平台运行均通过；console 中出现：

```text
LIFECYCLE_PRELOAD_ACTIVE=/lifecycle_event_preload.so run_id=r100-lifecycle-export nav_id=nav-00
MP_RENDERER_COUNT=2/3
MP_RENDERER_PIDS=315,369,389
```

但在 QEMU 固定时长结束前没有出现 `XK_LIFECYCLE_EXPORT_BEGIN`、`XK_LIFECYCLE_EXPORT_END` 或 lifecycle JSON 内容。`renderer_ready`、`browser_main_loop_ready` 和 `navigation_requested` 均没有可恢复的导出证据。

## 判定

R100 只证明 preload 被加载且进程枚举看到了 Renderer 候选，不能把进程枚举替代生命周期事件。该轮不进入正式启动/renderer/首帧指标，也不改变性能 0/0。导出函数已经加入临时运行脚本，但 cleanup 路径需要在下一轮单独定位：当前 QEMU 终止发生在 lifecycle probe 文件被导出之前。

原始 console、命令、平台检查、PPM SHA-256 和失败说明保存在 [R100 evidence](../evidence/2026-11-22_t490-r100-lifecycle-export/)。
