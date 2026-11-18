# 基于 x-kernel 的 Chromium 运行环境构建与优化

第三届"中国电子杯"高校 ICT 产教融合创新大赛 · **赛题六**（先进计算应用赛道，麒麟软件有限公司命题）

## 这是什么

在 AArch64 QEMU **纯 TCG** 软件模拟平台上，把 Chromium 142 跑进 Rust 编写的 x-kernel：
Weston 14（DRM/pixman）图形会话 + 单进程 Chromium 渲染组委会指定 HTML 页面。
同步完成内核 Linux 兼容性修复（8 项缺口、17 个补丁候选、上游 MR !831 已合并）、
可复现的性能测量方法与 400+ 轮归档证据。

## 2026-11-18 决赛验收状态

**浏览器功能：20/20 已有严格仓库验收记录**，使用 Chromium 149 默认 Browser → Zygote → Renderer、Wayland 和真实 QMP/HMP 输入；记录条件为 guest 4 GiB，见 [report/284](report/284-默认多进程真实键鼠与决赛20分闭环-20261117.md)。正式平台复验采用 `scripts/t490/platform.env` 的默认 2 GiB；指定首页已完成三次独立冷启动并通过 strict 像素判据，首个严格帧分别在 481 秒、420.8 秒和 420.8 秒出现，见 [report/287](report/287-T490-2GiB默认多进程首页冷启动首轮-20261117.md)、[report/288](report/288-T490-2GiB默认多进程首页冷启动第二轮-20261117.md) 与 [report/289](report/289-T490-2GiB默认多进程首页冷启动第三轮-20261118.md)。第三轮的 Browser → Zygote → Renderer 直接父链经原始 console 规范化复核通过；六项功能仍未全部在 2 GiB 下重验。

**仍待完成**：六项浏览器分数的完整 20/20 记录仍只在 4 GiB 条件下；2 GiB 已通过 HTML、Browser→Zygote→Renderer 父链及双页签，当前核实为 16/20（HTML、进程结构、双页签、JavaScript、CSS 已通过；Input 0/4）。Input r1 修复了 `os` import；r2 确认绝对指针不适用于 `virtio-mouse-pci`；r3 readiness 通过，但 HMP 相对鼠标与 QMP send-key 后文本框无回显、计数仍为 0；r4 改用 step4 步进鼠标后 JavaScript 自检通过，但文本框/计数 ROI 仍无变化。旧 gate 将交互页绿色条误判为 CSS 导航，修正后的官方布局 strict 重算已拒绝该帧；Input 仍为 0/4，详见 [report/306](report/306-T490-2GiB输入尝试r4-step4后焦点计数未响应及导航门禁修正-20261118.md)、[report/301](report/301-T490-2GiB输入尝试r1就绪后qmp助手NameError-20261118.md)、[report/302](report/302-T490-2GiB输入尝试r2绝对指针与virtio-mouse不匹配-20261118.md) 和 [report/303](report/303-T490-2GiB输入尝试r3-HMP相对鼠标页面无回显-20261118.md)。JavaScript r1 已通过 QMP Tab/Enter 触发 T1–T6 自检 6/6 和 F1 附加检查，见 [report/304](report/304-T490-2GiB-JavaScript键盘自检TabEnter通过-20261118.md)；CSS r1 的 T490 远端 gate 已通过（27 张中 23 张 strict 通过），见 [report/305](report/305-T490-2GiB-CSS布局页面strict通过及统一入口SSH收尾异常-20261118.md)；该轮外层 SSH 未返回，acceptance 记录的 rc255 与远端 gate 结果一并保留。双页签的两次 Ctrl+Tab 及三张 strict 截图见 [report/300](report/300-T490-2GiB双页签QMP切换通过-20261118.md)。稳定性 r10 首次通过正式 gate：14 guest 秒 family watchdog 目标周期下，strict 首页采样上界 466.573 秒、保持 1,805.0005 秒、10/10 次真实重载通过，60 个 host liveness 样本中的 family 年龄最大 30.047 秒；详见 [report/299](report/299-T490-2GiB稳定性尝试r10完整保持及十次重载通过-20261118.md)。r9 的 4 秒目标周期首屏超时，与 r10 形成单变量观察，但每种配置都只有一轮，不构成性能收益结论。兼容性矩阵仍有冻结版本复测缺项；四项性能指标的完整事件与 RSS/PSS/USS 数据、before/after 各五轮及优化结论仍待完成。

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

