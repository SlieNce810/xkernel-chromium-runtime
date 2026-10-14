# 基于 x-kernel 的 Chromium 运行环境构建与优化

第三届"中国电子杯"高校 ICT 产教融合创新大赛 · **赛题六**（先进计算应用赛道，麒麟软件有限公司命题）

## 这是什么

在 AArch64 QEMU **纯 TCG** 软件模拟平台上，把 Chromium 142 跑进 Rust 编写的 x-kernel：
Weston 14（DRM/pixman）图形会话 + 单进程 Chromium 渲染组委会指定 HTML 页面。
同步完成内核 Linux 兼容性修复（8 项缺口、17 个补丁候选、上游构建文档修复 PR !831 已合并）、
可复现的性能测量方法与初赛功能、性能和兼容性证据。

## 结果速览（判定只认 screendump 与日志，不凭报告转述）

| 维度 | 结果 | 归档证据 |
|---|---|---|
| 图形会话稳定 | Weston + x-kernel，单轮 **615 s**（门禁 600 s），跨日复现同过 | `evidence/2026-10-02_t490-single-initial-r5/`、`evidence/2026-10-05_t490-verify-b2-1005/` |
| 指定 HTML 渲染 | 官方 index 严格像素判据 **7/7 × 10 张**，`strict_fail=0` | r5 `ppm-summary.txt` + `screenshots/` |
| JS 交互 | interaction 页 T1–T6/F1 全绿 **6/6**，回显 `hello x-kernel` | `evidence/2026-10-02_t490-interaction-single-e2e-r20/` |
| CSS 布局 | 几何 **5/5**（r21 首屏）；6/6 结论条 **r19 + verify-c3-1013 两轮**（滚动视图 6 张判据过） | `evidence/2026-10-02_t490-layout-e2e-r21/`、`...-interaction-single-e2e-r19/`、`evidence/2026-10-13_t490-verify-c3-1013/` |
| 兼容性 | 8 项缺口（复现与未覆盖边界见 report/60）；17 个内核补丁候选；上游构建文档修复 PR !831 已合并 | `report/40`、`report/patches/` |
| 性能 | 5 轮中位数：首次发现导航开始日志 **75 s**、定时通过判据截图 **180.2 s**；host 侧峰值 RSS / CPU% | `evidence/2026-10-02_measure-single-perf3/`、`evidence/2026-10-13_measure-*/` |
| 演示 | VNC 演示轮 10/10 截图；**完整流程录屏已入库** | `evidence/2026-10-06_t490-vnc-demo/`、`evidence/2026-10-13_t490-demo-record-gtk-1013c/2026-10-13-demo-full-flow.mp4`（730 s/720p30/22.4 MB） |

**测量环境**（赛题 §七(二)4 要求注明）：T490 ThinkPad（Intel i7-8665U / 14.7 GiB / Ubuntu 26.04.1 LTS），
QEMU 10.2.1 **纯 TCG（命令行无 `-accel`，每轮断言）**；guest 2 GiB / 4 vCPU / cortex-a76；
设备组合 virtio-gpu-pci + virtio-keyboard/mouse-pci + virtio-blk-pci + virtio-net-pci。
功能证据统一为 QEMU monitor `screendump`；主机屏幕录像仅作演示辅助。

**2026-10-14 收口进展**：65 张缺失 PPM、两份 console 与录屏轮 12 份 guest 文件已回传并逐文件校验，详见 [恢复报告](report/59-T490原始证据回传与校验报告.md)。八条缺口复现、Linux/guest 对照及未覆盖项见 [附件](report/60-八条兼容性缺口复现与Linux对照附件.md)。未加适配器的历史 before 失败轮仍保留；共同 PI 中和适配器下另测 before/after 各五次，四项指标均无性能改善分证据，详见 [实测报告](report/64-共同用户态适配器before-after五轮实测.md)。报名表按用户要求跳过，学校盖章与技术主体身份页未声称已具备。

## 材料索引（初赛六件套 → 仓库位置）

| 赛题材料 | 位置 | 说明 |
|---|---|---|
| 技术方案文档 | [正式方案](report/56-正式技术方案文档.md) + [提交说明](report/40-初赛单进程提交材料与复现说明.md) | 正式报告含方案/架构/实现/验证/限制 |
| 代码仓库 | 本仓库（分支 `codex/initial-round-single-process`）+ 内核 Gitee fork（见下） | 内核改动 = fork 分支 `t490-chromium-runtime` |
| 构建配置 | `scripts/t490/platform.env`（QEMU 参数单一真源）+ 内核 `.config` | `.config` 见 `evidence/2026-09-22_t490-stage0-freeze/src-snapshot/.config`（sha256 `42e8d164…`，与组委会基线重展开逐字节一致） |
| 自动化测试脚本 | `scripts/t490/`（autorun 系列、`t490_round.sh`、`round_assert.sh`、`ppm_assert.py`、`measure-single-initial.sh`） | 一键起轮 + 像素判据 + 五轮测量 |
| 运行日志 | `evidence/` 主功能日志及各分轮材料 | 主功能、跨日轮、C3、录制轮日志及原件齐全；恢复来源见 report/59 |
| 演示视频 | `evidence/2026-10-13_t490-demo-record-gtk-1013c/2026-10-13-demo-full-flow.mp4` | OBS 录屏，730 s，页面连续存活约 10 分钟；sha256 `b8ee22f6…`；与录制轮一一对应 |

## 内核仓库与基线 tag（§七(二)3 复核存档代码）

| 项 | 值 |
|---|---|
| 内核仓库（fork） | `https://gitee.com/mofan0810/x-kernel`，分支 **`t490-chromium-runtime`** = `2a1b101` |
| 上游基线 | `https://gitee.com/openkylin/x-kernel`；本队 [PR !831](https://gitee.com/openkylin/x-kernel/pulls/831) **已合并**（2026-09-22 15:03:43，北京时间），修正失效的 defconfig 文档路径；落点 `0a04f7dcb99b18b93c83e6829d8eeb72efcab1ea`，详情见 [提交说明](report/40-初赛单进程提交材料与复现说明.md) |
| **首个可运行版本（before 基线）** | tag **`v0.1-first-runnable`** = `f8b9224`（Weston 会话可建、Chromium 可开窗显示本地 HTML） |
| 优化前完整兼容态 | tag `v0.2-compat-p0p4` = `7b60564` |
| 本仓库基线 tag | `v0.1-single-initial` → `65161a440a818fb35064f014b809d303de6d4f01`（2026-10-13 回读远端 peeled commit；tag 用于基线存档，最终材料从 `codex/initial-round-single-process` 获取） |
| 内核二进制哈希口径 | 镜像内嵌 `build_time`/`build_id`，同源码多次构建 sha256 不同；**tag 存档的是源码**，各轮实际哈希记录于该轮 `build-manifest.txt`（如 r5 = `dcb862c9…`、r20/r21/VNC 轮 = `7584653b…`、10-13 重建 = `2f873528…`） |

## 镜像与 overlay 获取

| 资产 | 规格 | sha256 | 获取 |
|---|---|---|---|
| 基础镜像 `agentos-weston.img` | 2 GiB（Weston+Chromium 142 预装） | `bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09` | **Release 资产**：`agentos-weston.img.xz`（344 MB，包 SHA-256 `6ed1bff70cabaa7d215693c10d2fef72f5f23d834031e260c70e5bcfae68e561`）<br>下载：<https://github.com/SlieNce810/xkernel-chromium-runtime/releases/download/v0.1-single-initial/agentos-weston.img.xz> |
| 运行时 overlay `eudev-seatprobe-libinput-swiftshader-p31.tar.gz` | 16 MB（guest 用户态补充包） | `56dba17c74ff80399d32a3fceef9ffa724a0197992fdc5934e0e254a8d8cf4b2` | **仓库内** `guest-overlays/` |

> ⚠️ 仓库根的 `agentos-disk.img.xz`（解出 `441b4504…`，2026-09-22 15:39）是**过期镜像**，
> 不含后续预装的 Weston/Chromium，**不能用于复现**；请以上表 `bb25e0b2…` 为准。

## 从冻结交付 ZIP 做干净 Linux 复现

交付包位于 report/submission/2026-10-14_xkernel-initial-submission-v2.zip；同目录的 .zip.sha256 是包文件 SHA-256。ZIP 内 SHA256SUMS 覆盖包内提交内容。下例通过 WSL2 Ubuntu 22.04 的新 HOME 完整执行：验证 ZIP、解包、校验所有文件、从独立源码归档构建内核、解压基础镜像并运行 900 秒功能轮。需要预装 QEMU 8.2.3、Rust 1.95.0、AArch64 musl 交叉工具链及 debugfs/e2fsprogs；脚本使用 WSL 现有依赖缓存，新建验证 HOME，不能复用已有验证目录。

```bash
PACKAGE_ZIP="/path/to/2026-10-14_xkernel-initial-submission-v2.zip"
RUNNER_DIR="$(mktemp -d)"
unzip -p "$PACKAGE_ZIP" scripts/t490/validate_delivery_package_wsl.sh > "$RUNNER_DIR/validate_delivery_package_wsl.sh"
bash "$RUNNER_DIR/validate_delivery_package_wsl.sh" "$PACKAGE_ZIP" "$HOME/xk6-submission-validation-20261014-v2"
```

验证器对会话期间的定时截图执行严格 gate；*-final.ppm 仍保留并独立统计为收尾诊断帧，因为 guest 服务可能在 QEMU 退出前结束。收尾帧不会替代或覆盖任何失败的定时帧。验证还要求 SINGLE_GATE=1 与平台 PASS=15/15。该验证是 WSL2 干净目录复现，不表示重装系统或使用第二台物理主机。完整日志、主机指纹、构建结果及截图摘要一并留在新 HOME 的 xk6/evidence 下。

## 手动 Linux 复现步骤

在干净 x86_64 Linux HOME 中放入 ZIP 与其 .zip.sha256 sidecar 后，使用包内资产建立源码和工作镜像：

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-8.2.3/bin:$HOME/musl/aarch64-linux-musl-cross/bin:/usr/sbin:/sbin:$PATH"
PACKAGE_ZIP="/path/to/2026-10-14_xkernel-initial-submission-v2.zip"
mkdir -p "$HOME/xk6"
unzip "$PACKAGE_ZIP" -d "$HOME/xk6"
(cd "$HOME/xk6" && sha256sum -c SHA256SUMS)
tar -xzf "$HOME/xk6/assets/x-kernel-source-2a1b101.tar.gz" -C "$HOME"
git -C "$HOME/x-kernel" checkout --detach 2a1b101ccf97ed255821b85628f366700089cda3
cp "$HOME/xk6/evidence/2026-09-22_t490-stage0-freeze/src-snapshot/.config" "$HOME/x-kernel/.config"
cd "$HOME/x-kernel"
make defconfig
make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n
mkdir -p "$HOME/x-kernel/images"
xz -dc "$HOME/xk6/assets/agentos-weston.img.xz" > "$HOME/x-kernel/images/agentos-weston.img"
cd "$HOME/xk6"
BASE_IMG="$HOME/x-kernel/images/agentos-weston.img" PKG_TARBALL="$PWD/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz" FINAL_FRAME_DIAGNOSTIC_ONLY=1 ASSERT_PROFILE=official-index FIRST_SHOT=180 SINGLE_HOLD_VALUE=600 STRICT_GATE=1 bash scripts/t490/t490_round.sh "my-repro-$(date +%H%M%S)" 900 60 autorun_single_initial.sh
```

上面的包校验后再构建；功能轮会输出 console.log、QEMU screendump、ppm-summary.txt 和平台合规结果。若还要重复测量，可在当前内核工作目录使用五轮驱动：

```bash
MEASURE_TAG_PREFIX="myperf-$(date +%H%M%S)" MEASURE_OUT_ROOT="$PWD/evidence/$(date +%F)_measure-myrepro-$(date +%H%M%S)" bash scripts/t490/measure-single-initial.sh
```

## 已知限制与如实口径（不超额宣称）

- **renderer 子进程**：未覆盖——初赛单进程路线（`--single-process --no-zygote`）为主动选择，非失败；多进程探索轮（`mp-*`）留存 T490。
- **键盘鼠标**：应用层输入事件（CDP/页面事件）通过（r20 6/6）；**内核 virtio-input 事件消费链是已知缺口**（缺口清单第 8 条）。
- **多窗口/多页面**：未覆盖，不在初赛宣称范围。
- **性能 before/after**：未适配器的基线 v0.1-first-runnable 因 PulseAudio mutex 断言和 crashpad 缺凭据而未能完成页面加载（report/57）；两版共同使用 PI 中和用户态适配器的五轮对照没有达到 5% 改善档位（report/64）。
- **perf/eBPF/火焰图**：T490 `perf_event_paranoid=4`，采样失败，原始报错已归档（`evidence/2026-10-02_profile-single/`）；未冒充任何 perf 结论。
- guest `/proc/<pid>/status` 的 `VmRSS` 不可用，内存指标采用 host 侧 QEMU 进程 RSS（已在报告中标注 host 观测属性）。

## 目录导览

```text
scripts/      t490/ 全部轮次与测量脚本；testpage/ 官方三页与像素判据参考图；wsl2/ 历史阶段脚本
evidence/     判据轮与演示轮全量证据（console.log、screendump、assert JSON、manifest、env）
report/       01–64 工作笔记与正式报告；patches/ 17 个补丁候选
guest-overlays/  运行时 overlay（16 MB）
docs/         赛题原文、操作卡（OBS 录屏、VNC 演示）
```
