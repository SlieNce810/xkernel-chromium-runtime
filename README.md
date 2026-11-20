# 基于 x-kernel 的 Chromium 运行环境构建与优化

第三届"中国电子杯"高校 ICT 产教融合创新大赛 · **赛题六**（先进计算应用赛道，麒麟软件有限公司命题）

## 这是什么

在 AArch64 QEMU **纯 TCG** 软件模拟平台上，把 Chromium 149 跑进 Rust 编写的 x-kernel：
Weston（DRM/pixman）图形会话 + 默认 Browser → Zygote → Renderer 多进程 Chromium，渲染组委会指定 HTML 页面。
同步完成内核 Linux 兼容性修复（8 项缺口、17 个补丁候选、上游 MR !831 已合并）、
稳定性与性能采集工具，以及 400+ 轮归档证据。

## 2026-11-20 当前复核状态

统一审计仍为 `INCOMPLETE`：历史 2 GiB R10 稳定性 gate PASS；最终候选 `ac1032fe…` 已有四次正式轮均未通过。首轮在重载阶段失败（7/10通过）；第二轮在2,400秒首屏 deadline 后仍无 strict 页面；第三轮首屏在371.4秒通过、nav-01通过，但nav-02在16次采样后 timeout，虽完成1,805秒保持仍仅1/10次重载通过；第四轮则在2,400秒首屏deadline后仍无strict页面，79次轮询失败。R3的65张周期截图中55张在首个通过帧后strict失败；shot-65逐帧JSON strict失败6项；旧字段 `last_pass=1` 表示本轮此前曾有strict通过，不表示末帧通过，字段语义与新增摘要列见 [report/358](report/358-ppm-summary-last_pass字段语义更正及round_assert摘要改进-20261120.md)。相同候选的30秒诊断通过8/8；120秒短诊断第一次未到首屏，第二次首屏496.611秒且driver8/8通过。R10基线120秒诊断也通过逐页driver8/8，但周期截图在542秒有一帧纯白，且一个进程族快照超35秒门槛41毫秒。Chromium trace诊断R1首屏和1/1次重载通过；R2验证单调时钟调度器输出五组快照，但700秒首屏deadline后仍未strict ready。所有trace诊断均不计正式稳定性；详情见 [report/345](report/345-T490-ac1032稳定性轮第八次重载页面无响应-20261119.md)、[report/348](report/348-T490-ac1032短间隔重载不复现nav08超时-20261119.md)、[report/349](report/349-T490-ac1032两分钟间隔诊断未到首屏-20261119.md)、[report/350](report/350-T490-R10基线120秒间隔诊断驱动通过但周期截图门禁失败-20261119.md)、[report/351](report/351-T490-ac1032匹配120秒诊断第二轮八次重载通过-20261120.md)、[report/352](report/352-T490-ac1032正式稳定性第二轮首屏超时纯白-20261120.md)、[report/353](report/353-T490-ac1032诊断日志采集r1页面通过但strace不可用-20261120.md)、[report/354](report/354-T490-ac1032诊断R2单调快照有效但首页首屏超时-20261120.md)、[report/356](report/356-T490-ac1032正式稳定性r3完整保持但第二次重载超时-20261120.md) 和 [report/361](report/361-T490-ac1032正式稳定性r4首屏超时及明确last_frame字段-20261120.md)。

当前 2 GiB 浏览器评分为 16/20（Input 0/4）；候选 Chromium 兼容性摘要通过；四项性能 before/after 有效运行仍为 0/0。最新逐项审计为 [goal-audit r5](evidence/2026-11-20_t490-final-report-r5/goal-audit.json)，整体 `INCOMPLETE`；阶段状态与剩余条款见 [report/362](report/362-决赛剩余任务阶段审计r5四次正式候选轮均失败-20261120.md)。短诊断 runner 已加入 `--dry-run` 与首屏等待时限检查；单调快照改动可触发五个日志窗口，但没有修复白屏。性能 trace 试采 R1 的 Chrome 启动参数未注入、trace 文件缺失；模板注入修复后，R13 dry-run 的参数注入、gzip/base64 round-trip 和分块自检通过；R12 的大体量串口 trace 仍有缺块，尚待用新 exporter 完成真实大文件回归，见 [report/363](report/363-T490性能trace试采r1未注入Chrome参数仅稳定性诊断通过-20261120.md) 与 [report/383](report/383-T490-proc-stat-starttime与进程树内存单遍回归-20261120.md)。
R12 trace/memory 诊断轮暴露出串口 base64 数据缺口及逐 PID 重复扫描开销；R13 已加入导出前 round-trip 校验与 `/proc/<pid>/tree_smaps_rollup` 单遍采样接口。内核以 `GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n` 构建通过；2 GiB guest shell smoke 得到 8 个有效样本、0 missed、16 行 RSS/PSS/USS、进程实例 `5-159`/`11-189`。该轮没有启动 Chromium/Weston，图形截图判据失败，不能算稳定性或正式性能样本；四指标仍为 0/0，见 [report/383](report/383-T490-proc-stat-starttime与进程树内存单遍回归-20261120.md)。
R14 复测通过相同的两进程 smoke，完整 16 行 CSV 和 4 条生命周期事件已从串口原文提取并校验（5 项提取器回归通过）；真实 Chromium 进程树与四项正式性能统计仍未完成，见 [report/384](report/384-T490-procfs-smoke原始数据串口回收与严格提取-20261120.md)。
R15 真实 Chromium 诊断通过首屏 strict 与 1/1 重载，trace 25,894 events/3,408 chunks 解码通过；进程树内存采样仍因 158 missed、161 错误而无效，未计入四指标样本，collect_metrics 仍因缺少 browser_main_loop_ready 事件拒绝该 ledger；详见 [report/386](report/386-T490二GiB真实Chromium首次帧trace成功但树内存采样超时R15-20261120.md)。
R16 关闭 trace 的同源内存控制轮在 700 秒首屏 deadline 超时，900 秒采样未完成；它不能用于解释 R15 内存 overrun，下一轮延长诊断 deadline 至 1200 秒，见 [report/387](report/387-T490二GiB无trace内存采样控制R16首屏超时无样本-20261120.md)。
`scripts/final-acceptance.sh --help` 与 `all` 全阶段 dry-run 已复核：入口路由全部 `rc=0`、QEMU 未启动、score 明确为 `NOT_RUN/20`；PowerShell 到 WSL 的环境变量需在 `bash -c` 内设置，详见 [report/385](report/385-T490统一验收入口help与全阶段dry-run复核-20261120.md)。

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

## 目录导览

```text
scripts/      t490/ 全部轮次与测量脚本；testpage/ 官方三页与像素判据参考图；wsl2/ 历史阶段脚本
evidence/     判据轮与演示轮全量证据（console.log、screendump、assert JSON、manifest、env）
report/       01–57 工作笔记与正式报告；patches/ 17 个补丁候选
guest-overlays/  运行时 overlay（16 MB）
docs/         赛题原文、操作卡（OBS 录屏、VNC 演示）
```
