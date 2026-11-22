# T490 Chromium 性能 Trace 试采 R10（2026-11-20）

## 结果

R10 在 T490 `10.249.11.192` 上以 2 GiB、AArch64 纯 TCG、Chromium 149.0.7827.53 运行。首页严格判据通过于启动后约 528.289 秒；页面截图为 1280×800，首屏与重载画面均可查看。650 秒诊断保持完成，QMP 查询维持 QEMU running，稳定性事件归一化 419/419 通过。

这一轮仍为 `diagnostic-only`，`STABILITY_GATE_RC=78`，不能计入正式稳定性验收。启动trace参数会增加诊断开销，且本轮只设置一次重载、没有十次加载与30分钟保持。驱动在 QMP 发出 `Ctrl+R` 后立即开始取严格截图：本轮导航请求记录在相对时间558.291秒，下一次通过截图在559.078秒。这样没有证明截图来自新导航；trace中reload相关的FCP候选时间为578.696秒，但trace与host时钟尚未校准。因此R10的 `1/1` 只记录驱动结果，不能作为有效重载通过数。正式稳定性轮前需加入导航后的最短等待并验证页面结果。

## Trace校验与指标状态

- 导出运行号：`codex-2026-11-20-perf-trace-r10`。
- 抽取器校验连续3,969块、BEGIN/END块数、gzip完整性、gzip与原始长度、gzip与原始 SHA-256、UTF-8 JSON和 `traceEvents` 数组均通过。
- 原始 JSON 为7,425,510字节，SHA-256 `db6690aae0c8fc28cf2433a6c92ea4a2242430a8c24324644b9326dff1e4b617`，包含30,055个事件。Trace时钟标记为 `LINUX_CLOCK_MONOTONIC`。
- Trace可见Browser主循环first-idle候选、导航事件、两个 renderer 的进程元数据及两条 First Contentful Paint 事件。`RenderProcessHostImpl::Init`、`RenderThreadImpl::InitializeRenderer` 和 channel-ready事件未出现在R10 trace中，故 renderer 创建时延不能计算。
- `Startup.BrowserMessageLoopFirstIdle` 记录从50.755936秒开始、407.155410秒结束。它是待验证的浏览器启动候选边界，不直接作为指标样本。
- R10没有进程树 `RSS/PSS/USS` 每秒采样。四项性能指标有效样本仍为0，尚未开始优化前后批次。

逐项事件见 [trace-events-inventory.txt](trace-events-inventory.txt)。完整串口、QMP、环境、运行参数、事件账本和原始trace JSON见 [remote-archive-no-ppm.tgz](remote-archive-no-ppm.tgz)。原始PPM留在T490，SHA-256见 [ppm-sha256.txt](ppm-sha256.txt)；可查看PNG见 [screenshots/](screenshots/)。非PPM归档 SHA-256 为 `0ccc54e20229a5e95073910a30b8135679bebc37b0b54a18a8f1748387830954`。

\n