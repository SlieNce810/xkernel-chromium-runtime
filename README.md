# 基于 x-kernel 的 Chromium 运行环境构建与优化

中国电子杯 · 赛题六。仓库同时保留两段交付：**决赛阶段的持续验收记录**（`main` 当前内容）与**初赛提交快照**（2026-10-14 冻结，tag `initial-submission-snapshot-20261014`）。

## 决赛阶段现状

在 AArch64 QEMU **纯 TCG** 软件模拟平台上，把 Chromium 149 跑进 Rust 编写的 x-kernel：
Weston（DRM/pixman）图形会话 + 默认 Browser → Zygote → Renderer 多进程 Chromium，渲染组委会指定 HTML 页面。
同步完成内核 Linux 兼容性修复（8 项缺口、17 个补丁候选、上游 MR !831 已合并）、
稳定性与性能采集工具，以及 400+ 轮归档证据。

## 2026-11-22 当前复核状态

冻结候选为 c80 no-direct-PTE、LOG_LEVEL_ERROR 内核，实际 Browser-run 二进制 SHA-256 为 `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`；源码基线 `b73e5814087c9d33c5f0a35b66cc56be689d3dee`，配置 SHA-256 `1d0ff69e…`。正式条件固定为 T490、AArch64 QEMU 纯 TCG、2 GiB、Weston 原生 Wayland、Chromium 149 默认 Browser → Zygote → Renderer 和真实 virtio 输入链路。

当前逐项审计已达到 **2 GiB 浏览器 20/20**：三次独立 HTML 冷启动、Browser→Zygote→Renderer 结构、双页签、JavaScript、CSS 和真实输入均有门禁证据。R70 在同一 a70e 候选上通过正式稳定性门禁（initial strict、10/10 真实重载、1804.991 秒保持、60 个 liveness 样本、0 退出/异常）；R70 进程结构复核为 4/4。R64 focused compatibility bundle 的 ABI 38/38、SCM_RIGHTS 6/6、memfd 12/12 和 procfs memory probe 已纳入候选兼容性摘要。

Input 的正式 2 GiB 证据为 [R78](evidence/2026-11-22_t490-r78-c80-tablet-input07/)：`input-gate.pass=1`、`pixel_policy_rc=0`、interaction-score gate=0；键盘回显、绝对 tablet 计数点击、CSS 顶部几何与底部 6/6 结论、真实 QMP 动作账本均通过。R72–R77 的失败和局部通过轮次继续作为回归材料保存，避免把冷启动长尾、评分器路径错误和输入链路问题混为一类，详见 [report/446](report/446-T490-R72-c80-absolute-tablet-input-failure-and-score-fix-20261122.md)、[report/448](report/448-T490-R74-c80-tablet-input-partial-pass-20261122.md)、[report/450](report/450-T490-R76-c80-tablet-input-subgates-pass-20261122.md)、[report/451](report/451-T490-R77-c80-tablet-cold-start-failure-20261122.md) 和 [report/452](report/452-T490-R78-c80-tablet-input-formal-pass-20261122.md)。

统一入口已加入内核 SHA-256 预检、tablet dry-run、绝对 pointer 事件统计、CSS 双帧判据和 readiness round 早停；`scripts/final-acceptance.sh all --dry-run` 的六阶段命令展开已通过。兼容性摘要见 [evidence/compatibility-final/summary.json](evidence/compatibility-final/summary.json)，R70 正式稳定性见 [report/444](report/444-T490-R70-a70e正式稳定性通过-20261122.md)，进程链复核见 [report/445](report/445-T490-R70-a70e候选Browser-Zygote-Renderer结构复核-20261122.md)。

当前总目标仍为 `INCOMPLETE`，剩余工作集中在高阶性能条款：浏览器启动时间、页面首帧、renderer 创建延迟和进程树 RSS/PSS/USS 峰值尚无有效 before/after 批次（0/0），还没有完成优化前后各五次独立运行和可复核收益结论。R79–R88 的采集器与优化诊断、无效样本和退化候选见 [report/454](report/454-T490-performance-r79-r85-invalid-sampler-and-optimization-review-20261122.md)、[report/455](report/455-T490-R86-fastpath-repeated-page-regression-20261122.md)、[report/456](report/456-T490-R87-procfs-try-lock-sampler-rejected-20261122.md) 和 [report/457](report/457-T490-R88-resident-page-retry-sampler-rejected-20261122.md)。本轮新增只读 procfs 进程树快照 MVP、R89/R91 复现证据、R92/R93 快照采样与内核计时诊断、R94 RSS-only 候选拒绝、R95 快速节奏诊断、R96 文件导出路径失败记录、R97 完整性校验导出、R98 延迟完整进程树导出、R99 延迟 60 样本内存窗口、R100/R101/R102 lifecycle preload 导出未完成记录、R103 部分 lifecycle 事件、R104 preload 继承诊断、Chromium lifecycle hook 机制编译诊断，以及 R81 的启动和严格截图部分数据，见 [report/458](report/458-T490-procfs-memory-snapshot-mvp-and-partial-performance-20261122.md)、[report/459](report/459-T490-xk-memory-snapshot-sampler-r92-diagnostic-20261122.md)、[report/460](report/460-T490-xk-memory-snapshot-timing-r93-20261122.md)、[report/461](report/461-T490-xk-rss-snapshot-r94-rejected-20261122.md)、[report/462](report/462-T490-xk-memory-snapshot-fast-r95-20261122.md)、[report/463](report/463-T490-xk-memory-snapshot-file-export-r96-failed-20261122.md)、[report/464](report/464-T490-xk-memory-snapshot-export-r97-pass-20261122.md) 和 [report/465](report/465-T490-xk-memory-snapshot-export-delayed-r98-20261122.md), [report/466](report/466-T490-xk-memory-snapshot-export-delayed60-r99-20261122.md) 和 [report/467](report/467-T490-lifecycle-preload-export-r100-incomplete-20261122.md)、[report/468](report/468-T490-lifecycle-periodic-export-r101-incomplete-20261122.md)、[report/469](report/469-T490-lifecycle-tmp-export-r102-incomplete-20261122.md)、[report/470](report/470-T490-lifecycle-watcher-r103-partial-events-20261122.md)、[report/471](report/471-T490-preload-attached-r104-renderer-inheritance-diagnosis-20261122.md)、[report/472](report/472-chromium-renderer-lifecycle-hook-compile-r104-20261122.md)。这些材料不改变正式性能 0/0 的判定。最新机器可复核审计为 `evidence/2026-11-22_t490-final-report-r6/goal-audit.json`。

## 2026-11-18 决赛验收状态

**浏览器功能：20/20 已有严格仓库验收记录**，使用 Chromium 149 默认 Browser → Zygote → Renderer、Wayland 和真实 QMP/HMP 输入；记录条件为 guest 4 GiB，见 [report/284](report/284-默认多进程真实键鼠与决赛20分闭环-20261117.md)。正式平台复验采用 `scripts/t490/platform.env` 的默认 2 GiB；指定首页已完成四次独立冷启动并通过 strict 像素判据，首个严格帧分别在 481 秒、420.8 秒、420.8 秒和 480 秒出现，见 [report/287](report/287-T490-2GiB默认多进程首页冷启动首轮-20261117.md)、[report/288](report/288-T490-2GiB默认多进程首页冷启动第二轮-20261117.md)、[report/289](report/289-T490-2GiB默认多进程首页冷启动第三轮-20261118.md) 与 [report/309](report/309-T490-2GiB指定HTML控制页冷启动strict通过-20261118.md)。第三轮的 Browser → Zygote → Renderer 直接父链经原始 console 规范化复核通过；六项功能仍未全部在 2 GiB 下重验。

**赛题原文平台核对**：本地 PDF 共 6 页。第七节(一)要求 AArch64 QEMU、QEMU 8.0+、计分轮纯 TCG、virtio GPU/input/block/network 与 monitor screendump；没有固定 guest RAM 数字。项目正式复验沿用 `platform.env` 的 2 GiB 默认，4 GiB 材料仍为历史条件。第六节的 1.5G 峰值内存资格线在原文中没有明确写 guest process tree RSS 还是 host QEMU RSS；已分别保留 guest RSS/PSS/USS 与 host QEMU 观测口径，资格线判定边界仍待明确，见 [report/329](report/329-赛题原文平台参数与1.5G口径核对-20261119.md)。

**仍待完成**：六项浏览器分数的完整 20/20 记录仍只在 4 GiB 条件下；2 GiB 已通过 HTML、Browser→Zygote→Renderer 父链及双页签，当前核实为 16/20（HTML、进程结构、双页签、JavaScript、CSS 已通过；Input 0/4）。Input r1 修复了 `os` import；r2 确认绝对指针不适用于 `virtio-mouse-pci`；r3 readiness 通过，但 HMP 相对鼠标与 QMP send-key 后文本框无回显、计数仍为 0；r4 改用 step4 步进鼠标后 JavaScript 自检通过，但文本框/计数 ROI 仍无变化。旧 gate 将交互页绿色条误判为 CSS 导航，修正后的官方布局 strict 重算已拒绝该帧；R5 交互页在 2,000 秒 ready timeout 后仍为空白、输入 driver 未启动；R6 同平台指定 HTML 控制页在 480 秒 strict 通过，故现有证据把问题范围收窄到交互页加载路径（根因未定），见 [report/307](report/307-T490-2GiB输入尝试r5-ready超时空白帧未进入输入driver-20261118.md) 与 [report/309](report/309-T490-2GiB指定HTML控制页冷启动strict通过-20261118.md)。R5 的轻量 Renderer PID 采样器自匹配另见 [report/308](report/308-T490轻量Renderer采样器自匹配修复-20261118.md)；R7 已通过键盘回显和 PageDown，鼠标计数与 CSS 导航仍失败，且滚动后全程 strict 会误判横幅离屏，见 [report/310](report/310-T490-2GiB输入尝试r7键盘回显通过鼠标计数导航未通过-20261118.md)。R8 在相同 2 GiB 条件下再次耗尽 2,000 秒仍未达到交互页 ready；Browser/Zygote IPC 活动仍在，但渲染结果持续空白，且本轮 renderer 采样与 evdev 事件记录均不足以判定进程/输入链状态，见 [report/311](report/311-T490-2GiB输入尝试r8交互页再次ready超时-20261118.md)。Input 仍为 0/4，详见 [report/307](report/307-T490-2GiB输入尝试r5-ready超时空白帧未进入输入driver-20261118.md)、[report/306](report/306-T490-2GiB输入尝试r4-step4后焦点计数未响应及导航门禁修正-20261118.md)、[report/301](report/301-T490-2GiB输入尝试r1就绪后qmp助手NameError-20261118.md)、[report/302](report/302-T490-2GiB输入尝试r2绝对指针与virtio-mouse不匹配-20261118.md) 和 [report/303](report/303-T490-2GiB输入尝试r3-HMP相对鼠标页面无回显-20261118.md)。JavaScript r1 已通过 QMP Tab/Enter 触发 T1–T6 自检 6/6 和 F1 附加检查，见 [report/304](report/304-T490-2GiB-JavaScript键盘自检TabEnter通过-20261118.md)；CSS r1 的 T490 远端 gate 已通过（27 张中 23 张 strict 通过），见 [report/305](report/305-T490-2GiB-CSS布局页面strict通过及统一入口SSH收尾异常-20261118.md)；该轮外层 SSH 未返回，acceptance 记录的 rc255 与远端 gate 结果一并保留。双页签的两次 Ctrl+Tab 及三张 strict 截图见 [report/300](report/300-T490-2GiB双页签QMP切换通过-20261118.md)。稳定性 r10 首次通过正式 gate：14 guest 秒 family watchdog 目标周期下，strict 首页采样上界 466.573 秒、保持 1,805.0005 秒、10/10 次真实重载通过，60 个 host liveness 样本中的 family 年龄最大 30.047 秒；详见 [report/299](report/299-T490-2GiB稳定性尝试r10完整保持及十次重载通过-20261118.md)。r9 的 4 秒目标周期首屏超时，与 r10 形成单变量观察，但每种配置都只有一轮，不构成性能收益结论。兼容性矩阵仍有冻结版本复测缺项；四项性能指标的完整事件与 RSS/PSS/USS 数据、before/after 各五轮及优化结论仍待完成。

**R9 输入复测**：关闭 evdev observer 后，`interaction.html` 在第 45 次采样通过 strict ready；JS 自检显示 6/6。30 秒 keyboard echo gate 未通过，但稍后的鼠标阶段截图中输入框和回显区都出现 `hello x-kernel`；HMP 点击后计数仍为 0，CSS 链接也没有导航，Input 继续为 0/4。R5 曾在无 observer 时 ready 超时，因此 R9/R8 还不能证明 observer 是启动失败的原因。报告与证据见 [report/312](report/312-T490-2GiB输入尝试r9交互页ready通过键盘回显延迟鼠标未通-20261118.md)。

**R10 探针复测**：`EVDEV_PROBE=1` 时 ready gate 在 2,000 秒后仍超时；sniffer 打开 keyboard/mouse event 节点，但因页面未 ready 没有输入事件。QMP 早退成功，QEMU 记录 2,013 秒即结束。R5 的 no-probe timeout 仍是反例，因此当前 probe-on/off 差异只作待复验线索，见 [report/313](report/313-T490-2GiB输入尝试r10探针开启ready超时及QMP早退-20261118.md)。

**R11 鼠标复核**：动态键盘等待已在 10 秒采样捕获 `hello x-kernel`；旧 mouse ROI 把光标移动误判为计数变化。收窄到计数文字后的 post-hoc gate 确认计数仍是 0；截图还显示 step4 相对指针落点与目标有明显偏差。已计算下一组候选坐标，尚待独立验证，见 [report/314](report/314-T490-2GiB输入尝试r11键盘回显通过鼠标计数ROI校正-20261118.md)。

**R12 指针坐标复测**：keyboard echo 与 JS gate 通过；新计数 ROI 确认鼠标仍未增加计数，CSS 链接也没有导航。更正后的按钮/链接坐标仍落在页面下缘，下一轮将改为单像素、较慢的相对步进，见 [report/315](report/315-T490-2GiB输入尝试r12修正坐标后鼠标点击仍未生效-20261118.md)。

**R13 step1 校准请求未生效**：launcher 请求 step1，但 T490 旧 runner 仍写死 step4；QMP ledger 证明本轮实际为 step4，因此 R13 不计作单像素验证。仓库 runner 已支持透传模式，下一轮同步后会核对双方哈希，见 [report/316](report/316-T490-2GiB输入尝试r13单像素模式未同步仍运行step4-20261118.md)。

**R14 真实 step1 试验**：runner/hash 已同步，ready 在第 46 次采样通过，Keyboard gate 通过；2,021 次相对移动后鼠标仍偏离目标，计数为 0，导航后截图出现 Page Unresponsive。下一轮改测 step3 中间步幅，见 [report/317](report/317-T490-2GiB输入尝试r14真实step1落点不足并出现页面无响应-20261118.md)。

**R15 step3 试验**：Keyboard gate 通过，CSS 链接点击实际打开了 layout 页；strict gate 因截屏仍在滚动视图而未认定成功。计数仍为 0，光标落到 CSS 链接附近，下一轮把计数点往左上修正并在导航后按 Home 截页顶，见 [report/318](report/318-T490-2GiB输入尝试r15-step3指针移动导航已发生计数未变-20261118.md)。

**R16 未到 ready**：step3 与修正计数位置/Home 截图路径没有执行；第 2,000 秒超时后 QMP quit 成功，保留 187 张 readiness 原图和 26 张正式 strict 失败截图。该轮不能判定交互修复效果，见 [report/319](report/319-T490-2GiB输入尝试r16计数坐标加home校正前ready再次超时-20261118.md)。

**R17 交互复核**：ready、JS、Keyboard gate 通过；HMP step3 导航实际打开了 CSS 页，但 Home 未将 viewport 回到顶部。计数仍为 0，截图测得指针落点偏移后已更新下一轮 counter 候选坐标；导航后改用 PageUp，见 [report/320](report/320-T490-2GiB输入尝试r17step3计数仍为零CSS页打开home未回顶-20261118.md)。

**R18 交互复核**：2 GiB 页面在第 47 次采样通过 ready，JS 与 Keyboard gate 通过；counter 仍为 0，HMP 点击未打开 CSS 页，因此不能判定 CSS 页面上的 PageUp 校正。QMP 正常退出；Input 仍为 0/4，见 [report/321](report/321-T490-2GiB输入尝试r18step3计数与导航仍失败-20261118.md)。

**R19 坐标外推反例**：第 45 次采样 ready、JS 和键盘通过；两点线性外推把 step3 相对光标移出画面底边，计数与 CSS 导航仍失败。R19 的跨日证据分置于 QEMU session 和 input work 两个原始目录，归档时保留二者并逐帧验证 PPM 哈希，见 [report/322](report/322-T490-2GiB输入尝试r19两点外推指针落至屏幕外计数与导航失败-20261119.md)。

**R20 counter 触发、CSS 导航未过**：第 47 次采样 ready、JS 与键盘通过。计数阶段截图仍为 0，但后续导航请求把计数变为 2，说明第二个相对移动点落在 counter；CSS 页面仍未打开，评分 gate 保持失败。R21 将先复测这个 counter 落点，见 [report/323](report/323-T490-2GiB输入尝试r20第二请求命中计数但CSS导航失败-20261119.md)。

**R21 首个 counter 请求也落出 viewport**：第 41 次采样 ready、JS 与键盘通过；把 `(350,710)` 移到首个 counter 阶段后，PPM 显示光标被裁在画面底边，计数仍为 0，第二次同点请求也没有变化。它与 R20 的顺序依赖结果表明 HMP 相对移动不能用跨轮两点线性模型预测，见 [report/324](report/324-T490-2GiB输入尝试r21同点首击仍在屏幕外-20261119.md)。

**R22 修正 mouse gate 假阳性**：as-run gate 将光标差分判成 counter 变化；原始 after-click 截图计数仍是 0。数字专用 ROI 复算为 0 像素变化，gate 已收窄并增加 cursor-only 与 digit-change 回归用例。CSS 导航仍失败，Input 仍 0/4；完整 session、QMP 与 PPM 哈希证据已归档，见 [report/325](report/325-T490-2GiB输入尝试r22数字ROI修正光标假阳性-20261119.md)。

**inotify/timerfd 对照**：WSL2 与 T490 native Linux 均通过 Linux 对照；最终 Browser-run 内核 `ac1032fe…` 上完整 `compatprobe` 矩阵 38/38、timerfd/inotify 子集 11/11。Chromium 首页日志的 7 次 `inotify_add_watch NotFound` 已追溯为 policy/time-zone 可选路径；Chromium 的 `FilePathWatcher` 会忽略不存在路径组件的 watch 错误并继续监视可访问父目录，见 [report/341](report/341-Chromium149-inotify可选路径NotFound分类-20261119.md)、[report/342](report/342-T490同一候选内核memfd与madvise兼容性修复-20261119.md) 和 [report/344](report/344-T490最终Browser-run内核兼容性矩阵复核-20261119.md)。

**SCM_RIGHTS short-read 对照**：WSL2 与 T490 native Linux 通过 6/6；最终 Browser-run 内核 `ac1032fe…` C guest probe 6/6，stream 单测 24/24。Chromium 首页 console 记录 157 条 fd 接收，final process gate 4/4。见 [report/328](report/328-SCM_RIGHTS-stream-shortread-WSL2-Linux基线与T490待补-20261119.md)、[report/331](report/331-T490-native-Linux-compat-memory-reference-20261119.md)、[report/332](report/332-T490-xkernel-inotify-scm-rights-procfs-probe-r1-20261119.md)、[report/333](report/333-SCM_RIGHTS首字节交付候选补丁与T490流回归-20261119.md)、[report/334](report/334-SCM_RIGHTS修复版guest短读复测-20261119.md)、[report/343](report/343-Chromium149最终候选SHA首页与进程链复验-20261119.md) 和 [report/344](report/344-T490最终Browser-run内核兼容性矩阵复核-20261119.md)。

**procfs 内存对照**：最终 Browser-run 内核 `ac1032fe…` 上 RSS/PSS/USS 的 file-shared、fork/COW、unmap 数值有效并匹配 Linux 主要变化；这是单/父子进程 probe，不是 Chromium 进程树 1 Hz/60 秒峰值样本。见 [report/330](report/330-procfs-memory-WSL2-reference-and-T490-followup-20261119.md)、[report/331](report/331-T490-native-Linux-compat-memory-reference-20261119.md)、[report/336](report/336-T490-native-Linux-procfs-memory-parser-r2-20261119.md)、[report/337](report/337-x-kernel-PSS-USS候选采样与MAP_PRIVATE差异-20261119.md)、[report/338](report/338-MAP_PRIVATE页缓存共享与PSS-USS-guest复测-20261119.md)、[report/342](report/342-T490同一候选内核memfd与madvise兼容性修复-20261119.md) 和 [report/344](report/344-T490最终Browser-run内核兼容性矩阵复核-20261119.md)。

**2 GiB 候选内核 Chromium 集成**：指定首页和 process gate 已在最终 Browser-run SHA `ac1032fe…` 上 strict 通过（10/16 张严格集截图通过，首个通过采样上界 601 秒；Browser → Zygote → Renderer 4/4）。同一 `ac1032fe…` C compatibility bundle 38/38、SCM_RIGHTS 6/6、memfd seals 12/12、PSS/COW/unmap 数值一致；完整六项、真实键鼠、候选内核稳定性和性能口径仍未完成。见 [report/343](report/343-Chromium149最终候选SHA首页与进程链复验-20261119.md) 和 [report/344](report/344-T490最终Browser-run内核兼容性矩阵复核-20261119.md)。

**统一 goal audit（2026-11-19）**：最新审计为 `INCOMPLETE`：2 GiB 得分 16/20（Input 未通过）；冻结基线历史 r10 稳定性通过；最终候选 SHA `ac1032fe…` 的正式稳定性轮在第八次重载出现 “Page Unresponsive”，7/10 通过，保持 1,805 秒但整体 gate 失败；同 SHA 兼容性矩阵 PASS；四项性能指标仍是 0 个有效样本。精确 R10 kernel `51c40285…` 与候选 `ac1032fe…` 在 30 秒间隔诊断中均 8/8 通过，未复现；根因仍与正式 120 秒间隔/更长时长的行为有关待查。诊断轮不计正式稳定性 gate。见 [report/345](report/345-T490-ac1032稳定性轮第八次重载页面无响应-20261119.md)、[report/347](<report/347-T490-R10 kernel短间隔八次重载控制通过-20261119.md>)、[report/348](report/348-T490-ac1032短间隔重载不复现nav08超时-20261119.md)、[本轮 audit JSON](evidence/2026-11-19_t490-final-report-r8/goal-audit.json) 和 [兼容性复核](report/344-T490最终Browser-run内核兼容性矩阵复核-20261119.md)。


统一验收命令、stage 说明和安全 dry-run 见[决赛复现与统一验收说明](docs/决赛剩余任务复现与统一验收.md)；入口是 `scripts/final-acceptance.sh`。

## 结果速览（判定只认 screendump 与日志，不凭报告转述）

| 维度 | 结果 | 归档证据 |
|---|---|---|
| 图形会话稳定 | Weston + x-kernel，单轮 **615 s**（门禁 600 s），跨日复现同过 | `evidence/2026-10-02_t490-single-initial-r5/`、`evidence/2026-10-05_t490-verify-b2-1005/` |
| 指定 HTML 渲染 | 官方 index 严格像素判据 **7/7 × 10 张**，`strict_fail=0` | r5 `ppm-summary.txt` + `screenshots/` |
| JS 交互 | interaction 页 T1–T6/F1 全绿 **6/6**，回显 `hello x-kernel` | `evidence/2026-10-02_t490-interaction-single-e2e-r20/` |
| CSS 布局 | 几何 **5/5**（r21 首屏）；6/6 结论条 **r19 + verify-c3-1013 两轮**（滚动视图 6 张判据过） | `evidence/2026-10-02_t490-layout-e2e-r21/`、`...-interaction-single-e2e-r19/`、`evidence/2026-10-13_t490-verify-c3-1013/` |
| 兼容性 | 8 项缺口（含最小复现 + Linux 对照）；17 个补丁；上游 MR !831 已合并 | `report/40`、`report/patches/` |
| 性能 | 5 轮中位数：首帧导航 **75 s**、首张通过判据截图 **180.2 s**；host 侧峰值 RSS / CPU% | `evidence/2026-10-02_measure-single-perf3/`、`evidence/2026-10-13_measure-*/` |
| 演示 | VNC 演示轮 10/10 截图；**完整流程录屏已入库** | `evidence/2026-10-06_t490-vnc-demo/`、`evidence/2026-10-13_t490-demo-record-gtk-1013c/demo-full-flow.mp4`（730 s/720p30/22.4 MB） |

**测量环境**（赛题 §七(二)4 要求注明）：T490 ThinkPad（Intel i7-8665U / 14.7 GiB / Ubuntu 26.04.1 LTS），
QEMU 10.2.1 **纯 TCG（命令行无 `-accel`，每轮断言）**；guest 2 GiB / 4 vCPU / cortex-a76；
设备组合 virtio-gpu-pci + virtio-keyboard/mouse-pci + virtio-blk-pci + virtio-net-pci。
功能证据统一为 QEMU monitor `screendump`；主机屏幕录像仅作演示辅助。

## 材料索引（初赛六件套 → 仓库位置）

| 赛题材料 | 位置 | 说明 |
|---|---|---|
| 技术方案文档 | `report/`（01–55 工作笔记）+ 正式设计报告（见 `report/56`） | 正式报告含方案/架构/实现/验证/限制 |
| 代码仓库 | 本仓库（分支 `codex/initial-round-single-process`）+ 内核 Gitee fork（见下） | 内核改动 = fork 分支 `t490-chromium-runtime` |
| 构建配置 | `scripts/t490/platform.env`（QEMU 参数单一真源）+ 内核 `.config` | `.config` 见 `evidence/2026-09-22_t490-stage0-freeze/src-snapshot/.config`（sha256 `42e8d164…`，与组委会基线重展开逐字节一致） |
| 自动化测试脚本 | `scripts/t490/`（autorun 系列、`t490_round.sh`、`round_assert.sh`、`ppm_assert.py`、`measure-single-initial.sh`） | 一键起轮 + 像素判据 + 五轮测量 |
| 运行日志 | `evidence/`（判据轮/演示轮全量入库）+ `report/patches/` | 404 轮在 T490，判据与演示轮已在库内 |
| 演示视频 | `evidence/2026-10-13_t490-demo-record-gtk-1013c/demo-full-flow.mp4` | OBS 录屏，730 s，页面连续存活约 10 分钟；sha256 `b8ee22f6…`；与录制轮一一对应 |

## 内核仓库与基线 tag（§七(二)3 复核存档代码）

| 项 | 值 |
|---|---|
| 内核仓库（fork） | `https://gitee.com/mofan0810/x-kernel`，分支 **`t490-chromium-runtime`** = `2a1b101` |
| 上游基线 | `https://gitee.com/openkylin/x-kernel`；本队补丁上游 MR **!831 已合并** |
| **首个可运行版本（before 基线）** | tag **`v0.1-first-runnable`** = `f8b9224`（Weston 会话可建、Chromium 可开窗显示本地 HTML） |
| 优化前完整兼容态 | tag `v0.2-compat-p0p4` = `7b60564` |
| 本仓库基线 tag | `v0.1-single-initial` = `3677524`（单进程路线首个可运行版本） |
| 内核二进制哈希口径 | 镜像内嵌 `build_time`/`build_id`，同源码多次构建 sha256 不同；**tag 存档的是源码**，各轮实际哈希记录于该轮 `build-manifest.txt`（如 r5 = `dcb862c9…`、r20/r21/VNC 轮 = `7584653b…`、10-13 重建 = `2f873528…`） |

## 镜像与 overlay 获取

| 资产 | 规格 | sha256 | 获取 |
|---|---|---|---|
| 基础镜像 `agentos-weston.img` | 2 GiB（Weston+Chromium 142 预装） | `bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09` | **Release 资产**：`agentos-weston.img.xz`（344 MB，包 sha256 `6ed1bff7…`）<br>下载：<https://github.com/SlieNce810/xkernel-chromium-runtime/releases/download/v0.1-single-initial/agentos-weston.img.xz> |
| 运行时 overlay `eudev-seatprobe-libinput-swiftshader-p31.tar.gz` | 16 MB（guest 用户态补充包） | `56dba17c74ff80399d32a3fceef9ffa724a0197992fdc5934e0e254a8d8cf4b2` | **仓库内** `guest-overlays/` |

> ⚠️ 仓库根的 `agentos-disk.img.xz`（解出 `441b4504…`，2026-09-22 15:39）是**过期镜像**，
> 不含后续预装的 Weston/Chromium，**不能用于复现**；请以上表 `bb25e0b2…` 为准。

## 最短复现路径（x86_64 Linux 主机，需 QEMU ≥ 8）

```bash
# 0) 依赖：qemu-system-aarch64 10.2.1、rustup（rust-toolchain.toml pin 1.95.0）、debugfs(e2fsprogs)
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$PATH"

# 1) 内核：fork 分支 + 组委会基线 .config
git clone https://gitee.com/mofan0810/x-kernel.git ~/x-kernel
cd ~/x-kernel && git checkout t490-chromium-runtime
cp <本仓库>/evidence/2026-09-22_t490-stage0-freeze/src-snapshot/.config .config
make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n     # 产物 target/xkmake/kplat-aarch64/release/kernel.bin

# 2) 镜像与 overlay
mkdir -p ~/x-kernel/images
# 从 Release 下载 agentos-weston.img.xz（344 MB）并解压到 ~/x-kernel/images/
# 下载页：https://github.com/SlieNce810/xkernel-chromium-runtime/releases/tag/v0.1-single-initial
#   https://github.com/SlieNce810/xkernel-chromium-runtime/releases/download/v0.1-single-initial/agentos-weston.img.xz
# （解压后镜像校验 bb25e0b2…，压缩包本身校验 6ed1bff7…）
xz -dc agentos-weston.img.xz > ~/x-kernel/images/agentos-weston.img

# 3) 跑一轮功能证据（官方 index 页，严格像素判据）
git clone https://github.com/SlieNce810/xkernel-chromium-runtime.git ~/contest
cd ~/contest
BASE_IMG=~/x-kernel/images/agentos-weston.img \
PKG_TARBALL=$PWD/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz \
ASSERT_PROFILE=official-index FIRST_SHOT=180 STRICT_GATE=1 \
bash scripts/t490/t490_round.sh my-repro-round 300 60 autorun_single_initial.sh
# 产物：evidence/<日期>_t490-my-repro-round/（console.log、screendump、ppm-summary、platform-compliance）

# 4) 五轮性能测量（中位数 + 波动范围 + host 指纹）
MEASURE_OUT_ROOT=$PWD/evidence/$(date +%F)_measure-myrepro \
bash scripts/t490/measure-single-initial.sh
```

## 已知限制与如实口径（不超额宣称）

- **renderer 子进程**：未覆盖——初赛单进程路线（`--single-process --no-zygote`）为主动选择，非失败；多进程探索轮（`mp-*`）留存 T490。
- **键盘鼠标**：应用层输入事件（CDP/页面事件）通过（r20 6/6）；**内核 virtio-input 事件消费链是已知缺口**（缺口清单第 8 条）。
- **多窗口/多页面**：未覆盖，不在初赛宣称范围。
- **性能 before/after**：基线 `v0.1-first-runnable` 已实测**无法完成页面加载**（ Weston 可起、Chromium 启动后中止：PulseAudio mutex 断言 + crashpad 缺凭据）；对比方法与原始数据见 `report/57`。
- **perf/eBPF/火焰图**：T490 `perf_event_paranoid=4`，采样失败，原始报错已归档（`evidence/2026-10-02_profile-single/`）；未冒充任何 perf 结论。
- guest `/proc/<pid>/status` 的 `VmRSS` 不可用，内存指标采用 host 侧 QEMU 进程 RSS（已在报告中标注 host 观测属性）。

R30 900秒内存bundle完整导出，但首页strict在1550秒deadline超时；240秒截图仍为Weston背景，1440秒和timeout截图为空白，Weston/Chrome进程仍存活。页面失败和采样错误已如实归档，排除稳定性及性能PASS；下一轮关闭采样/preload做最小页面复现，见 [report/401](report/401-T490R30默认多进程页面strict超时空白屏复现-20261121.md)。
R31 保持相同kernel/2 GiB/Wayland/默认多进程页面，关闭sampler、lifecycle preload与guest clock-sync后首页、重载、420秒保持通过，strict elapsed496.649秒。因一次改动多项观测设置，只说明最小配置可通过，不归因；R32将单独重新启用sampler，见 [report/402](report/402-T490R31关闭采样探针后的最小页面复现-20261121.md)。

R32 仅开启1 Hz memory sampler、关闭preload与clock-sync后，首页strict仍在1550秒deadline超时，Weston/Chrome仍存活；memory bundle完整但samplerFAIL（275 IDs、218 missed、280错误），不计PASS或峰值。R31/R32单轮结果提示采样负载相关，但不能确定唯一原因；R33重复sampler-off基线，见 [report/403](report/403-T490R32仅启用内存采样时页面strict超时-20261121.md)。

R33 sampler-off重复控制再次通过首页、重载、420秒保持，host elapsed465.692秒；240秒周期截图仍处于Weston阶段，normalizer另报family快照38.034秒stale，且guest clock-sync关闭，故不用于guest性能/稳定性总验收。R31/R33通过、R30/R32 sampler-on失败增强采样负载相关线索，但仍不能单因果归因，见 [report/404](report/404-T490R33sampler-off重复页面控制与时钟口径-20261121.md)。
R34 开启 sampler、关闭preload/clock-sync，并把 shell process-tree扫描设为30秒后首页 strict、重载与600秒保持通过；R32同条件但每5秒扫描时超时，支持诊断扫描负载相关。R34 sampler仍FAIL（274 IDs、215 missed、286错误），normalizer还有36秒family freshness超限，不能计峰值或稳定性PASS；见 [report/405](report/405-T490R34sampler与30秒process观察扫描对照-20261121.md)。
R35 恢复 preload、guest clock-sync 与1 Hz sampler，使用30秒process scan/25秒family watchdog后首页、重载、600秒保持和normalizer均通过；Browser launch→main-loop-ready为38.511秒、导航→strict截图上界436.389秒。sampler仍FAIL（268 IDs、194 missed、258错误），无有效RSS/PSS/USS峰值；renderer-ready/first-frame也缺，故不进入正式CSV，见 [report/406](report/406-T490R35低频Observer完整采集路径复测-20261121.md)。

R36 首次按冻结根路径重跑，kernel/rootfs SHA与baseline r3一致，2 GiB pure TCG、Jitless和IPC timeout flags均在argv；首页strict仍在1550秒诊断deadline超时，终止截图为空白。历史三次同SHA通过记录仍保留，但不能掩盖新失败；见 [report/408](report/408-T490冻结根51c冷启动strict超时R36-20261121.md)。
R37 在同一冻结根和默认2400秒ready deadline下通过首页strict（466.376秒）、1/1重载和420秒保持，但5个进程族快照超出35秒freshness门限，normalizer失败；该轮只能记页面/保持部分通过，不能算稳定性PASS，见 [report/409](report/409-T490冻结根R37coldstart页面通过但family快照stale-20261121.md)。
R38 在冻结根以15秒family watchdog重跑，首页strict于497.171秒通过、1/1重载及420秒保持通过；267条事件normalizer PASS，family freshness最大30.715秒。该轮仍是diagnostic-only，未执行正式10次重载/30分钟gate，且没有guest-clock性能或内存峰值数据；详见 [report/410](report/410-T490冻结根15秒familywatchdog冷启动与保持通过R38-20261121.md) 及 [R38 evidence](evidence/2026-11-21_t490-r38-frozen-cold02/)。
R39 使用相同冻结root/kernel和freshness设置独立复跑，首页strict 466.289秒通过、1/1重载、420秒保持通过；256条normalizer事件PASS，family age最大30.029秒。diagnostic-only正式gate跳过，未采guest-clock性能或RSS/PSS/USS峰值，详见 [report/411](report/411-T490冻结根独立冷启动复现与freshness通过R39-20261121.md) 与 [R39 evidence](evidence/2026-11-21_t490-r39-frozen-cold03/)。
R40 在同一冻结根、2 GiB和15秒family watchdog下，首页strict在默认2400秒内超时，79次页面检查均未通过；240秒截图全白，1440秒和最终timeout截图相同。Weston/Browser仍存活，normalizer 793/793通过，但process-family snapshots最大间隔93.572秒且正式gate跳过。R38/R39通过、R40超时，故当前冷启动结果仍显示显著长尾/间歇失败，详见 [report/412](report/412-T490冻结根默认deadlineR40strict页面超时-20261121.md) 与 [R40 evidence](evidence/2026-11-21_t490-r40-frozen-cold04/)。
R41 在同一冻结root/kernel下首页strict 466.226秒通过，确认第三个独立初始首页成功；真实Ctrl+R的nav-01在90秒窗口中11次检查均未strict，整轮driver fail（reload 0/1），但完成420秒观察保持，normalizer 266/266通过。R40首页timeout、R41重载timeout仍使稳定性结论INCOMPLETE，见 [report/413](report/413-T490冻结根R41首页通过但CtrlR重载超时-20261121.md) 与 [R41 evidence](evidence/2026-11-21_t490-r41-frozen-cold05/)。
R42 首次首页strict 465.976秒通过；正式10次重载/1805秒保持门禁中，nav-01至nav-08通过、nav-09超时，hold 1805.000秒通过但总结果 `8/10`、formal gate FAIL。终态截图显示Chromium“Page Unresponsive”对话框，底层页仍在；具体阻塞点仍待trace定位。normalizer 746/746 PASS，family age最大30.022秒；采样器关闭，无性能峰值数据。详见 [report/414](report/414-T490冻结根正式稳定性R42八次重载与1805秒保持但nav09超时-20261121.md) 和 [R42 evidence](evidence/2026-11-21_t490-r42-frozen-formal01/)。
R43 复跑正式门禁，首页strict 497.108秒通过、nav-01/02通过、nav-03 timeout，driver后续nav未执行；初始strict后1805.000秒保持完成，但总结果2/10、formal gate FAIL。normalizer 739/739通过，family age最大28.895秒；nav-03终态为白屏。R42/R43 reload hang位置不同，见 [report/415](report/415-T490冻结根正式稳定性R43两次重载后nav03超时-20261121.md) 与 [R43 evidence](evidence/2026-11-21_t490-r43-frozen-formal02/)。
R44 首次完成正式稳定性gate：冻结根首页strict 497.079秒通过，10/10真实Ctrl+R重载通过，初始strict后保持1805.000秒；liveness 60样本，family freshness最大30.024秒，进程退出/异常均为0。gate PASS。该轮关闭内存 sampler/生命周期/guest-clock探针，因此不提供四项正式性能数据；该PASS只针对冻结kernel/rootfs，候选谱系仍待核准。详见 [report/416](report/416-T490冻结根正式稳定性R44十次reload与1805秒保持通过-20261121.md) 与 [R44 evidence](evidence/2026-11-21_t490-r44-frozen-formal03/)。
R45 首次在同一冻结根开启preload、guest clock-sync及900秒memory sampler：首页558.501秒、1/1 reload、420秒保持通过；Browser launch→main-loop-ready候选39.769秒，navigation→strict-screenshot上界410.029秒。生命周期缺renderer-ready/first-frame；memory bundle完整但CSV0行、734 missed、1,357采样错误，故账本和四指标样本均无效。空CSV extractor现已修复为保存bundle并标valid=false，11项回归通过；详见 [report/417](report/417-T490R45lifecycle与内存采集诊断采样器零有效行-20261121.md) 及 [R45 evidence](evidence/2026-11-21_t490-r45-frozen-lifecycle-memory01/)。性能before/after仍0/0。

## 目录导览

```text
scripts/      t490/ 全部轮次与测量脚本；testpage/ 官方三页与像素判据参考图；wsl2/ 历史阶段脚本
evidence/     判据轮与演示轮全量证据（console.log、screendump、assert JSON、manifest、env）
report/       01–57 工作笔记与正式报告；patches/ 17 个补丁候选
guest-overlays/  运行时 overlay（16 MB）
docs/         赛题原文、操作卡（OBS 录屏、VNC 演示）
```

## 初赛提交快照（2026-10-14 冻结）

正式交付仅面向 T490 原生 Linux，采用 AArch64 QEMU 纯 TCG、Weston 和 Chromium 142 单进程路线。

正式材料入口是 [初赛提交说明](submission/README.md)、[精简技术方案](submission/技术方案.md) 和 [唯一证据集说明](submission/证据说明.md)。最终 ZIP 位于 `report/submission/xkernel-initial-final.zip`，同目录提供包 SHA-256 和文件清单；请从该 ZIP 解压复现。

提交物包含一份 T490 证据集、一份 2026-10-14 新录的 945 秒录像、内核源码与配置、用户态 overlay，以及依赖闭合的 T490 运行脚本。基础镜像从固定 Release 获取并核对 SHA-256。包的精确白名单为 `submission/selection.json`。

主流程保持 615 秒，官方 index 严格判据通过；JS/CSS 验收、八条兼容性缺口及五次性能观测见精简方案。硬件输入链、renderer 多进程和性能改善档位均不超额宣称。上游 [PR !831](https://gitee.com/openkylin/x-kernel/pulls/831) 已合并，见技术方案。

`report/`、未选入的 `evidence/` 与历史脚本为研究归档。Windows/WSL2 仅用于开发测试，相关脚本、证据和验证说明不进入初赛提交物。该约束记录在 `AGENTS.md` 和项目记忆。报名表按用户要求跳过。
