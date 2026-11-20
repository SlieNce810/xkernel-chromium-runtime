# T490 2 GiB Chromium 149 trace 与进程树内存 R15（2026-11-20）

## 结论

R15 是 diagnostic-only 的真实 Chromium 观测轮，不是正式性能样本或稳定性验收。T490 AArch64 纯 TCG、2 GiB、Wayland 下，Chromium 149 启动、指定首页 strict、一次真实 Ctrl+R strict 均通过；首次首页 strict 的上界为 620.566 秒，800 秒 host 单调保持和 1/1 次重载完成，`STABILITY_DRIVER_RC=0`。诊断 runner 因 `STABILITY_DIAGNOSTIC_ONLY=1` 将 `STABILITY_GATE_RC=78`，所以本轮不能代表 30 分钟/十次加载正式 gate。

trace gzip/base64 串口块完整，抽取器校验后得到 25,894 个事件；内存包 framing/tar/gzip 也可解码，但实际内存样本无效：sampler 状态 `FAIL`，160 个成功 sample ID 中产生 158 次 missed，另有 161 条内存/树遍历错误。R13/R14 两进程 smoke 的 8/8 结果未代表真实 Chromium 树负载。R15 暴露当前单遍 mapcount 快照仍不能满足 1 Hz 全树采样。

证据：[evidence/2026-11-20_t490-r15-procfs-bulk-trace](../evidence/2026-11-20_t490-r15-procfs-bulk-trace/)。T490 上保留全部 PPM 原件；逐张 SHA-256 清单为 [`evidence/_ppm-sha256-r15-procfs-bulk-trace.txt`](../evidence/_ppm-sha256-r15-procfs-bulk-trace.txt)。strict 页面截图为 [首页](../evidence/2026-11-20_t490-r15-procfs-bulk-trace/stability/load-00-initial.png) 与 [重载页](../evidence/2026-11-20_t490-r15-procfs-bulk-trace/stability/load-01-reload.png)。

## 冻结条件

- T490：ThinkPad T490，QEMU `10.2.1`，AArch64 `kplat-aarch64`，纯 TCG，4 vCPU，`-m 2g`，virtio GPU/input/block/network；平台参数来自 `scripts/t490/platform.env`。
- 基础镜像：`/home/mo/x-kernel/images/pkg-installed.img`，SHA-256 `d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`；Chromium `149.0.7827.53`。
- 内核源码树 HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`，该 T490 工作树保留此前已有的未提交兼容改动；实际启动 kernel.bin SHA-256 `f988d68b3d8545875af30a931734b5936f9a13b9850df67b8fe8b074a7ccb3f1`。
- probe 参数：startup trace categories `startup,ipc,loading,blink,cc,viz,navigation`，trace 500 秒，memory sampling 900 秒，14 秒进程族 watchdog，1 次 Ctrl+R、30 秒 settle、800 秒 diagnostic hold。额外 trace 和内核 IPC 日志开启，本轮适合定位和采集能力验证，不用于优化前后性能对照。

## 页面与 trace

稳定性 driver 记录：`page_ready` strict `true`、`navigation_id=nav-00`、ready elapsed `620566.394582 ms`；真实 Ctrl+R 后 `page_verdict` strict `true`、`navigation_id=nav-01`；`monitor_end` measured `800.000445159 s`、reloads `1/1`。Chromium 的 `process tree` 在 console 里有 Browser PID 71、Zygote 和 renderer 子进程活动。

串口 trace BEGIN 声明 raw `6,454,340` 字节、SHA-256 `00f06b97756b1aee3a630ac2d2fdb5ca6ee4b3ff44c97642795515853cbdaad9`；gzip `654,286` 字节、SHA-256 `5d1b87f207fb7e45dade856fc75b138ad6c671c6f0992438c579ed67499eee9e`；3,408 块。`extract_perf_trace.py` 验证所有块、base64、压缩/原始长度与 SHA、JSON `traceEvents`，抽取得 25,894 个 trace events。

trace 中可复核的候选 landmark（trace `ts` 为微秒，当前只作诊断分析）：

- `Startup.BrowserMessageLoopFirstIdle` 的 B/E 片段约在 `52.632 s` 与 `446.639 s`；guest lifecycle 的 `browser_launch_requested` 为 `40.881 s`。若两者共用 guest 单调时钟，端到端约 `405.758 s`，但时钟原点映射尚未写入正式采集器，不能作为已验收启动时间。
- 初始 `file:///usr/share/html-test/index.html` 导航 trace 约从 `124.531 s` 开始；`Display::FrameDisplayed` 最早记录 `619.774 s`，`Startup.FirstWebContents.NonEmptyPaint3` 为 `620.211 s`。这与 host screenshot driver 的 620.566 秒 strict 通过相互吻合，但仍需在统一 guest 时钟事件账本中完成导航/renderer 身份关联后，才能成为正式 first-frame 指标。
- trace 内可见 `NavigationRequest::ReadyToCommitNavigation`、`RenderProcessHostImpl::IsSuitableHost` 以及 compositor frame/presentation 事件；当前没有足够证据把 Browser 的 create request 与对应 renderer ready 组成精确配对，renderer-create 延迟暂不可用。

trace 的类别覆盖与 QMP 截图提供了页面活动的交叉核验，但测量窗口仅 500 秒，且详细 IPC 日志开启。直接用 R15 的 memory lifecycle CSV 调用 `collect_metrics.py` 会在指标计算前拒绝：`expected one browser_main_loop_ready event, found 0`；对应判据输出保存在 `collect-metrics-validation.json`。目前还没有把 browser-ready、renderer request/ready、首帧、导航和 page verdict 统一为已验证的 guest 单调时钟账本，所以本轮没有有效的正式四指标样本。

## 内存采集结果

内存 exporter 的 BEGIN/END、65 个 base64 数据块、压缩 SHA 与 tar SHA 均校验通过。解包结果在 `memory-export/`：

- `memory-samples.csv`：1,054 行，160 个 sample ID，10 个进程实例；
- `memory-sampling-errors.log`：161 条错误；其中 130 条采样耗时超过 1.5 秒，25 次 `/proc` 进程树不可用，3 次 bulk endpoint 不可用，3 条 sample incomplete；
- `sampler_overrun_ms` 中位数 `3035.5 ms`，最小 `1608 ms`，第 95 百分位 `27941.9 ms`，最大 `43230 ms`；
- status：`result=FAIL`、`missed=158`、`memory_source=procfs-tree-smaps_rollup`。

`extract_perf_memory.py` 正确保留这组数据并标记 `valid=false`，没有把缺失/超时样本当作有效峰值。当前 `procfs-tree-smaps_rollup` 已避免逐 PID 重复执行全局 mapcount 遍历，但在真实 Chromium 树中仍需定位热点；trace 诊断和串口 IPC 日志也可能增加负载，因此下一步先做不启用 startup trace 的 memory-only 单变量复测，再评估 page-table/PFN mapcount 算法。R15 的 RSS/PSS/USS 数值不能进入资格线或正式峰值报告。

R16 关闭 startup trace 后在 700 秒 ready deadline 内未通过 strict，driver QMP quit 时 900 秒 memory window 尚未完成，因此不能归因 R15 overrun 到 trace；R16 控制轮见 [report 387](387-T490二GiB无trace内存采样控制R16首屏超时无样本-20261120.md)。 R17 延长 deadline 后 strict 首页和 1/1 重载通过，但 trace-off memory sampler 仍有 213 missed；详情见 [report 388](388-T490二GiB无traceChromium内存采样仍超时R17-20261120.md)。

## 后续验收

本轮只有一个 strict 首页与一次重载、约 13 分钟 host hold；尚未满足三次独立冷启动、30 分钟保持、十次加载或每组五次性能样本。浏览器冷启动、renderer create 和 first-frame 指标尚未全部进入统一有效样本；before/after 仍为 `0/0`。R15 用来证明 trace 传输可校验、页面/renderer trace 可观察，并揭示 memory tree sampler 在实际 Chromium 负载下的 overrun。
