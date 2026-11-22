# T490 R104 preload inheritance diagnosis（2026-11-22）

R104 在 preload constructor 最早位置新增 `preload_attached` 事件，并使用独立 watcher 导出 lifecycle probe。host extractor 选择最后一个完整 export block，完整性校验通过。

## 事件结果

恢复的 lifecycle JSON 包含：

- Browser/zygote 等 PID 的 `preload_attached`；
- `browser_main_loop_ready`；
- 5 个 `zygote_fork_boundary`，带 child PID 和 request ID；
- `navigation_requested`。

R104 的真实 Renderer 候选来自 zygote fork child 和 `MP_RENDERER_PIDS`：`352`、`398`、`462` 等，但这些 PID 没有对应的 `preload_attached` 事件。因而 `renderer_ready` 没有产生。

这组证据把缺口定位到 Chromium zygote 的 preload 继承边界：Browser/zygote 进程执行了 preload，Renderer 子进程没有执行该 `.so`。问题不再是 `/root`/`/tmp` 事件文件路径，也不是 export 传输损坏。

证据文件：

[lifecycle-probe-events.jsonl](../evidence/2026-11-22_t490-r104-preload-attached-r2/lifecycle-probe-events.jsonl)

[R104 evidence](../evidence/2026-11-22_t490-r104-preload-attached-r2/)

## 判定

R104 不进入正式性能 CSV，也不把 `renderer-observed` 进程枚举升级成 `renderer_ready`。下一步应在 Chromium/zygote 侧加入可追溯的 Renderer ready hook，或实现独立的 Browser IPC/连接 observer；继续修改事件文件路径不会解决 Renderer 没有继承 preload 的事实。
