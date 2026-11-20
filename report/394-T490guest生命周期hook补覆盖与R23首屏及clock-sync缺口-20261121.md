# T490 guest 生命周期 hook 覆盖补测 R23（2026-11-21）

## 结论

R23 改用 `CrBrowserMain` / `CrRendererMain` 线程 comm 检查，并拦截 epoll、poll、ppoll。与 R22 相比，Browser main-loop readiness hook 命中，file URL open 继续命中；真实 QEMU 会话完成首页 strict、1/1 重载和 420 秒 driver 保持，结束前 watchdog 仍报告 Weston 与 Chrome 存活。

R23 仍不构成有效性能样本：first-frame 与 renderer-ready 事件缺失，strict 截图发生在900秒 sampler/clock-sync窗口之后，QMP时间无法映射到 guest 时钟。内存 sampler 仍 `FAIL`。新 hook 只补上了 Browser readiness 和进程角色旁证，renderer-create latency、页面 first-frame 和峰值内存仍不可用。

## 单调时钟事件

R23 memory lifecycle ledger：Browser launch request `t_ns=41,442,182,032`，Browser 进程 PID 72、实例 `72-4161` 在 `43,779,474,416 ns` 被采样器观察。preload 捕获的 `browser_main_loop_ready` 来自 Browser 主线程第一次 poll/epoll 等待，`t_ns=83,732,651,392`，相对 launch request 的 guest-clock 启动候选为 **42.290 s**。这是一条 source-defined diagnostic candidate，尚未进入完整指标样本。

指定 HTML 的 Browser `openat` 事件 `navigation_requested` 是 `t_ns=211,439,471,888`（PID 72 / `72-4161`）。该事件对应 file URL loader 打开本地 HTML 的时刻。preload 记录的 Zygote fork boundary 在 111.759、135.743、137.590、186.653 和 188.981 秒，其中四次发生在 HTML 文件打开之前；它们不能直接归为该导航的 renderer-create request。

同一 raw console 中的 shell `MP_EVENT renderer-observed` 告诉我们下列 PID 被 guest process observer 识别为 renderer：PID 388、442、446、597、604，观察时间分别是 173.851、175.534、260.567、262.535、264.462 秒。合并工具已把这些观察按 PID 与 `PID-start_ticks` process instance 关联，产出 [`lifecycle-events.role-normalized.jsonl`](../evidence/2026-11-21_t490-r23-lifecycle-hooks/lifecycle-events.role-normalized.jsonl)。PID 388/442 在文件 open 导航前已被观察，PID 446/597/604 在其后出现；仍不能选择实际提交首帧的 renderer。该观察表示进程角色已被识别，不是 IPC ready 确认，不能代替 `renderer_ready`。

QMP strict 首帧 host elapsed 为 987.609 秒（首帧截图采样上界，30 秒轮询间隔）。guest sampler/clock-sync 窗口约在 943.678 秒结束；QMP page-ready host 时间在最后一个 guest sync anchor 之后，合并器拒绝外推，摘要记录 `page_ready clock mapping failed: outside guest clock-sync anchors`。因此没有把 host page-ready 时间伪装成 guest `t_ns`。时钟范围和事件缺项见 [`lifecycle-merge-role-summary.json`](../evidence/2026-11-21_t490-r23-lifecycle-hooks/lifecycle-merge-role-summary.json)。

`collect_metrics.py` 对 PID/角色归一化后的 ledger 拒绝样本：`expected one first_valid_frame for navigation nav-00, found 0`；见 [`collect-metrics-role-normalized-validation.json`](../evidence/2026-11-21_t490-r23-lifecycle-hooks/collect-metrics-role-normalized-validation.json)。

## 内存采样结果

| 项目 | R23 |
|---|---:|
| sampler 状态 | `FAIL` |
| sample ID / CSV 行 | 167 / 1,053 |
| status process instances / 内存行实例 | 11 / 9 |
| missed / memory errors | 251 / 303 |
| error types | 33 tree unavailable；52 bulk unavailable；52 incomplete；166 overrun |
| overrun min / median / P95 / max | 1.603 / 3.341 / 8.123 / 10.874 s |
| 合法 RSS/PSS/USS peak | 否 |

采样窗口是900秒；R23首页 strict 出现在987.609秒 host elapsed，时钟同步范围未覆盖该画面。guest 的进程树内存高峰与QMP页面事件均不能纳入正式 before/after 指标。

相邻 R21/R22 页面 ready 约589秒；R23接近988秒。额外 preload 热路径和短采样窗口可能影响启动，R23与前轮不能视为严格单变量配对，也不能据此接受收益或退化。

## 下一步修正与复现

- `lifecycle_event_preload.c` 现版在 hook 已命中后使用一次性快路径；R23实际编译的 preload 使用较早版本，精确源与二进制 hash 见 [lifecycle-probe-identities.txt](../evidence/2026-11-21_t490-r23-lifecycle-hooks/lifecycle-probe-identities.txt)。下一轮先做相同guest条件复测，确认快路径能否恢复首屏时间。
- R23 capture 里 Renderer 的 comm/cmdline 角色出现滞后，sampler先报 `zygote`、后报 `child`；shell观察器稍后才报 `renderer-observed`。role-change事件已进入合并器，但仍需接入 renderer-main readiness 与 frame-to-renderer identity。
- 下轮 memory/clock-sync窗口应延长到覆盖 strict 首屏后至少60秒，避免QMP verdict 落在 guest clock-sync anchor 外；renderer request 必须与同一 child PID、request ID 的 ready 事件配对。没有 first-frame 的 sample 继续拒收。

## 本轮采集器回归

采集完成后在 Windows 工作树运行仓库 Python unittest 全集：`python -m unittest discover -s scripts/tests -p 'test_*.py' -v`，73项通过；`git diff --check` 通过。将现版 preload、原生 smoke 程序和 fixture 复制到在线 T490，在 Linux host 上运行 `bash /tmp/codex-lifecycle-r23-check/scripts/t490/test_lifecycle_preload_native.sh`，结果 `LIFECYCLE_PRELOAD_NATIVE_SMOKE=PASS waits=epoll,poll,ppoll fork-ready=paired`。该 smoke 验证 hook 编译、epoll/poll/ppoll 命中以及合成 zygote fork 与 renderer-ready 的 PID/request-ID 配对；它不替代 R23 guest Chromium 的缺失 ready/frame 事件。

相关脚本检查、采样器回归和 R23 原始记录见 [R23 evidence](../evidence/2026-11-21_t490-r23-lifecycle-hooks/)。原始PPM保留在T490，对应哈希索引为 [`evidence/_ppm-sha256-r23-lifecycle-hooks.txt`](../evidence/_ppm-sha256-r23-lifecycle-hooks.txt)。
