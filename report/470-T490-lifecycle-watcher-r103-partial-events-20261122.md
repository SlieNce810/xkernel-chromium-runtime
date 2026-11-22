# T490 R103 lifecycle watcher partial events（2026-11-22）

R103 启动独立 guest lifecycle watcher，在 Browser 启动后轮询 `/tmp/lifecycle-probe-events.jsonl`，一旦文件出现就通过压缩串口协议导出。host extractor 支持同一轮多次 export，选择最后一个完整 block；R103 的两次 export 均完整，后一个 block 已恢复。

恢复出的 [lifecycle-probe-events.jsonl](../evidence/2026-11-22_t490-r103-lifecycle-watcher/lifecycle-probe-events.jsonl) 包含：

- `browser_main_loop_ready`；
- 5 个 `zygote_fork_boundary`，都关联 `nav-00` 和 child PID；
- `navigation_requested`，对应指定 HTML 页面。

它没有包含 `renderer_ready`。Renderer 子进程是通过旧的 `MP_RENDERER_PIDS` 进程枚举观察到的，但没有相应 preload 事件，所以没有把枚举记录提升成 renderer-ready/connection-confirmation 事件。`first_valid_frame` 也没有生成。

这轮把问题范围从“lifecycle 文件无法传输”缩小为“Renderer 子进程没有继承或执行 preload hook”。R103 不进入正式性能 CSV，但前半段 Browser/zygote/navigation 事件可作为下一步修复的时钟和导航关联基线。

证据目录还包含两次 export 的原始 console、导出校验 JSON、命令、平台检查、PPM SHA-256 和 artifact 清单：

[R103 evidence](../evidence/2026-11-22_t490-r103-lifecycle-watcher/)
