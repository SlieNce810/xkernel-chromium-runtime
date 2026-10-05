# 47 · PDF 逐条手动验证步骤（无脚本方案）

> 用途：用户逐条手动执行、把每一步的完整输出贴回，由 AI 对照本 PDF 要求核验并出汇总报告。
> **不调用任何仓库自动化脚本**（`t490_round.sh` / `measure-single-initial.sh` 等一律不用），
> 只用直接命令：`ssh` / `ls` / `cat` / `grep` / `sha256sum` / `git` / QEMU monitor 原生命令。
> PDF 依据：`docs/报名资料/附件2…/6 赛题六…pdf`（下称「PDF」），条款引用均为 PDF 原文摘录。

## 0. 使用说明

**环境与路径对照（易踩坑，先看这里）**：

```bash
# 本机 Git Bash 登录 T490（后续所有「T490 上执行」的步骤，先登录一次，命令块整段复制）
ssh -i /c/Users/12697/.ssh/id_ed25519_t490 mo@192.168.1.217
```

| 资源 | 本机（Windows，仓库根 `E:\02_competition\中电杯`） | T490（远端） |
|---|---|---|
| 证据目录 | `evidence/<目录名>/` | `~/xk6/evidence/<目录名>/` |
| 脚本与测试页 | `scripts/`、`scripts/testpage/` | `~/xk6/scripts/` |
| 内核仓库 | （无） | `~/x-kernel/` |

**规则**：本文出现的 `evidence/…` 相对路径——
- 在本机执行时：直接 `cd /e/02_competition/中电杯` 后原样可用；
- 在 T490 执行时：**必须加 `~/xk6/` 前缀**（例：`cat ~/xk6/evidence/2026-10-02_t490-single-initial-r5/cmd.txt`）。

**执行位置总表**：

| 位置 | 步骤 |
|---|---|
| 本机 Git Bash（`cd /e/02_competition/中电杯`） | S3、S12、S13、S14(前半)、S15、S20、S21、S22 |
| T490（`ssh mo@192.168.1.217` 后） | S1、S2、S4、S5、S6–S11、S14(后半)、S16–S19、S22(后半)、S23 |
| 两处均可（本机更快） | S6–S10（evidence 两处都有同一归档） |

**回贴格式**（每步都按此贴，方便我逐条核）：

```text
=== S7 ===
$ grep -E "SINGLE_HOLD_REACHED|SINGLE_GATE" console.log
<把完整输出原样贴在这里，不要删改、不要截断中间；输出超过 80 行就贴前 50 行+后 20 行并注明总行数>
```

**步骤索引与 PDF 条款对应**：

| 步骤 | 验证内容 | PDF 条款（原文摘录） | 当前位置 |
|---|---|---|---|
| S1 | QEMU 版本与 TCG | 七(一)2「版本不低于 8.0……纯 TCG……初赛阶段统一禁用 KVM/HVF」 | T490 |
| S2 | 组委会基线配置 | 七(一)1「x-kernel kplat-aarch64 平台及组委会发布的 qemu_defconfig 基线配置」 | T490 |
| S3 | 完整运行命令逐项核对 | 六(一)「提供 screendump 截图、日志与完整运行命令」+ 七(一)1/2/3 | 本机 |
| S4 | 二进制指纹存档 | 七(二)3「提交时存档 git tag 与原始数据，组委会复核存档代码」 | T490 |
| S5 | git tag 基线 | 七(二)1「以参赛队伍首个可运行版本（git tag 存档）为基线」 | T490 |
| S6 | 归档证据文件齐全 | 六(一)「缺证据按项计 0 分」 | T490 |
| S7 | 图形会话启动 + 10 分钟稳定 | 六(一)「成功启动图形会话 10 分；连续稳定运行不少于 10 分钟且 compositor 无退出 10 分」 | T490 |
| S8 | screendump 截图证据 | 七(一)4/3「功能证据统一采用 QEMU monitor screendump 截图」 | T490 |
| S9 | Chromium 启动并创建窗口 | 六(一)「Chromium 成功启动并创建窗口 10 分」 | T490 |
| S10 | 指定 HTML 正确渲染 | 六(一)「正确渲染组委会指定 HTML 页面 10 分」 | T490 |
| S11 | 现场直播复现（可选） | 六(一)「现象与数据可复现 4 分」 | T490 |
| S12 | 统一验收场景 7 项覆盖度 | 六「测试内容至少覆盖：图形界面稳定运行、简单 HTML 显示、Chromium 窗口创建、renderer 子进程、键盘鼠标输入、多窗口/多页面和页面截图」 | 本机（预填+确认） |
| S13 | 缺口清单与复现方法 | 六(一)「整理系统调用与内核接口缺口清单并附复现方法 8 分（每个缺口 1 分，最多计 8 个）」 | 本机 |
| S14 | 补丁上游合并 | 六(一)「一个高质量 patch 被上游合并 4 分，最多计 3 项」 | 本机+T490 |
| S15 | Linux 基线对比 | 六(一)「与 Linux 行为基线的对比分析 5 分」 | 本机 |
| S16 | 5 次中位数+波动范围 | 七(二)4「每项指标重复不少于 5 次取中位数，提交原始数据与波动范围」 | T490 |
| S17 | 宿主机指纹 | 七(二)4「注明宿主机 CPU 型号、内存、QEMU 版本与操作系统，供交叉核验」 | T490 |
| S18 | 指标覆盖广度 | 六(一)「覆盖 2 类 1 分、3 类 2 分、不少于 4 类 4 分」 | T490 |
| S19 | 性能改善 before/after | 六(一)「以队伍首个可运行版本为基线……无对比数据 0 分」+ 七(二)1/3 | T490 |
| S20 | 设计报告结构 | 六(一)「设计报告结构完整 5 分」 | 本机 |
| S21 | 代码与配置说明 | 六(一)「关键代码与配置说明详实 5 分」 | 本机 |
| S22 | 初赛材料六件套 | 六「提交技术方案文档、代码仓库、构建配置、自动化测试脚本、运行日志和演示视频等材料」 | 本机+T490 |
| S23 | 完整流程录屏 | 六(一)「完整流程录屏 6 分」 | 本机+T490 |
| S24 | 数据可复现 | 六(一)「现象与数据可复现 4 分」 | T490 |

**现状预判**（我据已有归档证据的先验判断，执行后以回贴输出为准）：

| PDF 评分项 | 满分 | 预判 | 关键短板 |
|---|---:|---:|---|
| 图形环境启动与稳定性 | 20 | ✅ 20 | — |
| 浏览器基础功能 | 20 | ✅ 20 | — |
| 系统兼容性与移植分析 | 25 | ⚠️ 12–20 | Linux 基线对比（S15）、上游合并项数（S14）待确认 |
| 性能观测与量化方法 | 15 | ⚠️ 8–12 | 指标覆盖（S18）、before/after 改善数据（S19，大概率 0） |
| 技术文档与代码规范 | 10 | ✅–⚠️ 8–10 | 视 S20/S21 回贴 |
| 演示效果 | 10 | ❌–⚠️ 4–10 | **录屏大概率缺失（S23）** |

---

## 1. 阶段 P · 平台与运行环境（全部后续项的前置）

### S1 · QEMU 版本与纯 TCG

- **PDF 依据**：七(一)2「qemu-system-aarch64 版本不低于 8.0。全部评分数据必须出自纯 TCG 软件模拟环境，初赛阶段统一禁用 KVM/HVF 等硬件加速」。
- **T490 上执行**：

```bash
qemu-system-aarch64 --version | head -1
ls -la /dev/kvm 2>&1
```

- **预期**：`QEMU emulator version 10.2.1 …`（≥8.0）；`/dev/kvm` 可有可无（宿主事实，与评分无关）。
- **检查点**：版本号 ≥8.0。**纯 TCG 的硬判据不在这里**，在 S3 的"命令行无 `-accel`"。

### S2 · 组委会基线构建配置

- **PDF 依据**：七(一)1「统一采用 AArch64 QEMU 虚拟平台（x-kernel kplat-aarch64 平台及组委会发布的 qemu_defconfig 基线配置）」。
- **T490 上执行**：

```bash
ls -la ~/x-kernel/platforms/kplat-aarch64/qemu_defconfig
grep -E '^ARCH=|^MACHINE_AARCH64_QEMU=|^KFEAT_DRIVER_VIRTIO_GPU=|^KFEAT_DRIVER_VIRTIO_INPUT=|^KFEAT_VIRTIO_BUS_PCI=' ~/x-kernel/.config
grep -E '^ARCH_(RISCV64|X86_64|LOONGARCH64)=y' ~/x-kernel/.config; echo "grep_rc=$?"
```

- **预期**：defconfig 存在；`.config` 中 `ARCH="aarch64"`、`MACHINE_AARCH64_QEMU=y`、`KFEAT_DRIVER_VIRTIO_GPU=y`、`KFEAT_DRIVER_VIRTIO_INPUT=y`、`KFEAT_VIRTIO_BUS_PCI=y` 五条全中；最后一条 grep 无输出、`grep_rc=1`（未混入其他架构）。
- **检查点**：6 项全中即 PASS；任一不符即 FAIL（后续所有数据失去平台合规前提）。

### S3 · 完整运行命令逐项人工核对

- **PDF 依据**：六(一)「提供 screendump 截图、日志与完整运行命令」；七(一)1/2/3。
- **本机执行**：

```bash
cd /e/02_competition/中电杯
cat "evidence/2026-10-02_t490-single-initial-r5/cmd.txt"
```

- **或在 T490 执行**（注意 `~/xk6/` 前缀）：

```bash
cat ~/xk6/evidence/2026-10-02_t490-single-initial-r5/cmd.txt
```

- **预期**：文件含「① 脚本命令行 ② make 命令 ③ QEMU 字面命令行（多行+单行）④ guest 内命令」四段。
- **检查点**：对 ③ 的单行命令逐条人工打勾，8 项全中方为 PASS：
  1. `-cpu cortex-a76`（非 `host`，本身即 TCG 证据）
  2. 命令行**没有任何 `-accel`**（纯 TCG 唯一硬判据）
  3. `-machine 'virt,gic-version=3'`
  4. `-m 2g`、`-smp 4`
  5. 四类设备齐全：`virtio-gpu-pci`、`virtio-blk-pci`、`virtio-net-pci`、输入（`virtio-keyboard-pci` + `virtio-mouse-pci`）
  6. `-serial 'mon:stdio'`（monitor 取证通路）
  7. `-vga none`
  8. `-kernel` 指向的 kernel.bin 路径与 S4 哈希对应

### S4 · 二进制指纹与存档

- **PDF 依据**：七(二)3「提交时存档 git tag 与原始数据，组委会复核存档代码」。
- **T490 上执行**：

```bash
sha256sum ~/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin
sha256sum ~/x-kernel/images/agentos-weston.img
sha256sum ~/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz
ls -la ~/x-kernel/disk.img && sha256sum ~/x-kernel/disk.img
```

- **预期**：前三个分别 = `dcb862c9e83d…`（r5/perf3 轮内核）、`bb25e0b298d6…`、`56dba17c74ff…`；`disk.img` 是轮次工作盘（注入了测试页与 autostart，**允许与 BASE_IMG 不同**，若相同反而说明注入没生效）。
- **检查点**：三哈希对号入座；`disk.img` 存在与否记录在案（S11 直播复现要用它）。

### S5 · git tag/分支存档

- **PDF 依据**：七(二)1「性能改善数据以参赛队伍首个可运行版本（git tag 存档）为基线」。
- **T490 上执行**：

```bash
cd ~/x-kernel && git tag --list && git describe --tags --always --dirty && git status --porcelain | wc -l
cd ~/xk6 && git rev-parse --abbrev-ref HEAD && git describe --tags --always && git status --porcelain | wc -l
```

- **预期**：`x-kernel` 有 tag（含 `v0.1-single-initial`）、`describe` 无 `-dirty`、porcelain 行数 0；`xk6` 在 `codex/initial-round-single-process`、工作区干净。
- **检查点**：① 工作区必须干净（否则"采数二进制≠存档代码"）；② **重点记录 tag 列表**——"首个可运行版本"是哪一支直接决定 S19 能不能做；若只有 `v0.1-single-initial` 一个 tag，S19 按无基线处理。

---

## 2. 阶段 F · 功能证据（40 分主体）

> 以下 S6–S10 全部在 `evidence/2026-10-02_t490-single-initial-r5/` 内核查（T490 上先 `cd ~/xk6/evidence/2026-10-02_t490-single-initial-r5`，本机仓库 evidence/ 下有同一归档，两处任选，本机即可）。

### S6 · 归档证据文件齐全性

- **PDF 依据**：六(一)「缺证据按项计 0 分」。
- **执行**：

```bash
ls
ls screenshots/ | wc -l; ls ppm-assert-shot-*.json | wc -l; ls ppm-diff-shot-*.json | wc -l
```

- **预期**：12 个标准文件（`build-manifest.txt cmd.txt console.log env.txt manifest.txt pages.txt platform-check.txt platform-compliance.txt ppm-summary.txt timestamps.csv` + `screenshots/`）；screenshots 10 个 PPM、assert JSON 10 个、diff JSON 9 个。
- **检查点**：三组计数 = 10/10/9 且标准文件无缺失。

### S7 · 图形会话启动 + 连续稳定 ≥10 分钟 + compositor 无退出

- **PDF 依据**：六(一)「成功启动图形会话 10 分；连续稳定运行不少于 10 分钟且 compositor 无退出 10 分」。
- **执行**：

```bash
grep -E "SESSION START|WESTON_SOCKET|SINGLE_HOLD_REACHED|SINGLE_GATE" console.log
grep -c "weston_alive=1" console.log; grep -c "browser_alive=1" console.log; grep -c "alive=0" console.log
grep -E "SESSION END" console.log
```

- **预期**：`SESSION START` + `WESTON_SOCKET=wayland-1`（compositor 已启动）；`SINGLE_HOLD_REACHED elapsed=615`（≥600）；`SINGLE_GATE=1`；`weston_alive=1` 计数 = 采样点数且 `alive=0` 计数 = 0；`SESSION END (exit=0)`（正常收尾）。
- **检查点**：四项全中 = 20 分项达标。`elapsed` ≥600 是硬线；`alive=0` 出现任意一条即 FAIL。

### S8 · screendump 截图证据的形式合规

- **PDF 依据**：七(一)3「功能证据统一采用 QEMU monitor screendump 截图，主机屏幕录像仅作演示辅助，不作为验收依据」。
- **执行**：

```bash
sed -n '/① screendump 清单/,/② 会话收尾/p' ppm-summary.txt
head -c 20 screenshots/shot-01-at0180s.ppm | od -c | head -2
```

- **预期**：清单显示 10 张、尺寸集合单元素 `1280x800`、字节数集合单元素 `3072016`；PPM 头为 `P6` 二进制位图（`od -c` 可见 `P 6 \n 1 2 8 0 …`）。
- **检查点**：10 张 + 尺寸唯一 + raw P6 格式（即 monitor screendump 原生产物，非录屏转裁）。

### S9 · Chromium 启动并创建窗口

- **PDF 依据**：六(一)「Chromium 成功启动并创建窗口 10 分」。
- **执行**：

```bash
grep -E "FIRST_NAV_ELAPSED|BROWSER_PID|CHROME_ARGS=|PAGE_URL|chromium=" console.log | cut -c1-160
grep -E "SAMPLE elapsed=(600|615)" console.log
```

- **预期**：`BROWSER_PID=48`（进程创建）、`FIRST_NAV_ELAPSED=75`（页面开始加载即窗口已建立并有内容）、`PAGE_URL=file:///usr/share/html-test/index.html`（指定页面）、`chromium=Chromium 142.0.7444.59`；600/615 s 采样仍 `browser_alive=1`。
- **检查点**：PID + 首次导航 + 入口 URL 三者齐即 PASS。"创建窗口"的物证 = 全屏 kiosk 窗口渲染出的页面本身（S8/S10 的截图）。

### S10 · 指定 HTML 正确渲染（含人工目视）

- **PDF 依据**：六(一)「正确渲染组委会指定 HTML 页面 10 分」。
- **执行**：

```bash
grep -E "严格集未通过|尺寸不符|^GATE" ppm-summary.txt
grep -E '"check"|"pass"' ppm-assert-shot-01-at0180s.json
```

- **预期**：`严格集未通过 : 0`、`尺寸不符张数 : 0`、`GATE strict_fail=0 probe_fail=0`；shot-01 的 JSON 中 7 个 core 检查全部 `"pass": true`。
- **人工目视检查点**（额外做一次，判据工具是我们的自建工具，评委目视比对才是终审）：把 `screenshots/shot-01-at0180s.ppm` 转 PNG 后打开，确认四色块同行等宽、表格有边框线、列表+SVG、表单控件四类元素都在、无白屏无花屏。转换可用一次性工具（`python3 tools/ppm2png.py`，属查看工具非自动化流程）。
- **判定**：`strict_fail=0` + 目视四类元素齐全 = PASS。

### S11 · 现场直播复现（可选但强烈建议，约 10 分钟）

- **PDF 依据**：六(一)「现象与数据可复现 4 分」；七(一)4 monitor screendump。
- **前提**：S4 确认 `~/x-kernel/disk.img` 存在（含注入页面与 autostart 的工作盘）。
- **T490 上执行**（整段照抄，一条一行）：

```bash
cd ~/xk6 && mkdir -p tmp
qemu-system-aarch64 -m 2g -smp 4 -cpu cortex-a76 -machine 'virt,gic-version=3' -kernel /home/mo/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin -device 'virtio-blk-pci,drive=disk0' -drive 'id=disk0,if=none,format=raw,file=/home/mo/x-kernel/disk.img' -device 'virtio-net-pci,netdev=net0' -netdev 'user,id=net0,hostfwd=tcp::61005-:5555,hostfwd=udp::61005-:5555' -device virtio-gpu-pci -vga none -serial 'mon:stdio' -object 'rng-random,id=host_rng0' -device 'virtio-rng-pci,rng=host_rng0' -device virtio-keyboard-pci -device virtio-mouse-pci
```

然后**纯手动操作**：
1. 盯着串口输出，等出现 `FIRST_NAV_ELAPSED` 或 `[single] SAMPLE elapsed=180`（约 3–6 分钟，TCG 慢属正常）；
2. 按 `Ctrl-a` 松开再按 `c` 进入 QEMU monitor（提示符变 `(qemu)`）；
3. 执行 `screendump /home/mo/xk6/tmp/live-s11-01.ppm`；
4. 执行 `info status`、`info block`（记录虚拟机状态与块设备）；
5. `quit`（或 `Ctrl-a` `x`）退出。

```bash
sha256sum ~/xk6/tmp/live-s11-01.ppm ~/xk6/evidence/2026-10-02_t490-single-initial-r5/screenshots/shot-01-at0180s.ppm
```

- **预期**：虚拟机正常启动、页面出现；两次 screendump 的 SHA-256 **相同**（index 纯静态页、SwiftShader 软件光栅确定性输出，历史轮次内部已验证可复现）。
- **预期噪声（不是故障，2026-10-05 实测定性）**：串口会周期性出现
  `knet::transport::tcp:447 [KErrorKind::ConnectionRefused] connection refused`（约每 5 s 一条）。
  实测相关性 1:1——**开了 `--remote-debugging-port` 的轮次才出现**（r19/r20/r21 各 34–36 条，且它们的判据全部通过）；
  未开 DevTools 的轮次为 0 条（r2/r5/single-profile 均为 0）。属 Chromium DevTools 调试端口探测噪声，
  不影响图形/页面判定。另有 `landlock_create_ruleset` 未实现告警，同属无害探测。
- **检查点**：
  1. 哈希相同 = 像素级复现（最强证据）；不同 = 不判 FAIL，把新 PPM 转 PNG 与**对应页面**的归档图目视比对，差异原因写进汇总；
  2. ⚠️ **先确认本轮加载的页面再去比对**：比对基准必须同页——`PAGE_URL=…/index.html` 对 r5 的 `shot-01`；
     `…/layout.html` 对 r21；`…/interaction.html` 对 r20。**先看直播输出头部的 `PAGE_URL` 与 `FIRST_NAV_ELAPSED`**
     （index 轮历史值 75 s、CDP 轮 90 s），若与任何归档值都不同，说明 `disk.img` 里的 autorun 是另一轮注入的版本，
     此时只把"会话起来 + 页面渲染出来"计为现象复现，像素哈希仅作参考。
- **若 `disk.img` 不存在**：跳过本步，在汇总登记"工作盘已清理，直播复现未执行"——不影响归档证据效力，只影响 S24 的得分底气。

---

## 3. 阶段 C · 统一验收场景覆盖度（第六节 7 项）

### S12 · 七项覆盖度逐项登记

- **PDF 依据**：六「测试内容至少覆盖：图形界面稳定运行、简单 HTML 显示、Chromium 窗口创建、renderer 子进程、键盘鼠标输入、多窗口/多页面和页面截图」。
- **本机执行**：无新命令，对照下表逐项确认/修改（我按现有归档预填，你确认或纠正）：

| # | PDF 覆盖项 | 证据 | 状态 |
|---|---|---|---|
| 1 | 图形界面稳定运行 | S7：615 s、weston_alive=1 | ✅ |
| 2 | 简单 HTML 显示 | S10：strict_fail=0 ×10 | ✅ |
| 3 | Chromium 窗口创建 | S9：BROWSER_PID + kiosk 全屏渲染 | ✅ |
| 4 | renderer 子进程 | 单进程路线 `--single-process --no-zygote`，**无 renderer 子进程**；多进程尝试全部 `MP_RENDERER_SEEN=0` | ❌ 未覆盖 |
| 5 | 键盘鼠标输入 | 应用层（CDP/页面事件）6/6 通过；内核 virtio-input 消费未打通（report/44） | ⚠️ 部分 |
| 6 | 多窗口/多页面 | kiosk 单页，未做双标签/多窗口 | ❌ 未覆盖 |
| 7 | 页面截图 | S8：10 张 monitor screendump | ✅ |

- **检查点**：**4/5/6 三项必须在提交材料中如实写明"未覆盖/部分覆盖及原因"**。初赛评分表虽未单列这 7 项，但第六节明文"至少覆盖"，材料评审时对不上就是主动送疑点。单进程路线是明确的初赛策略选择（report/42 已声明），关键是材料里要说清，而不是假装覆盖。

---

## 4. 阶段 X · 系统兼容性与移植分析（25 分）

### S13 · 缺口清单 ≤8 且附复现方法（8 分项）

- **PDF 依据**：六(一)「整理系统调用与内核接口缺口清单并附复现方法 8 分（每个缺口 1 分，最多计 8 个）」。
- **本机执行**：

```bash
sed -n '/兼容性缺口与补丁候选/,/^Wayland/p' report/40-初赛单进程提交材料与复现说明.md
```

- **预期**：收敛后 8 条（fd/zygote 继承；Unix ancillary+半关闭；ppoll_time64；procfs 字段；PR_SET_PDEATHSIG；TCP keepalive；futex PI+RLIMIT_NOFILE；virtio-input 消费），每条带"现象/最小复现/Linux 对照/影响/补丁或限制"。
- **检查点**：① 条数恰好 8（不多不少）；② 抽查 3 条：其"最小复现"命令在 T490 上是否真的能跑出所述现象（复现探针在 `scripts/t490/` 下，如 `p33_pi_mutex.c`→`EOPNOTSUPP`）；③ virtio-input 一条的复现 = report/44 的 QMP/evdev 对照描述。抽跑 3 条即可，不必全跑。

### S14 · 上游合并补丁（12 分项，最多 3 项）

- **PDF 依据**：六(一)「修复与补丁实现质量 12 分（一个高质量 patch 被上游合并 4 分，最多计 3 项）」。
- **本机执行**：

```bash
ls report/patches/
```

- **T490 上执行**（查上游合并凭证，按 report/39 记录 MR !831 已合并）：

```bash
cd ~/x-kernel && git log --oneline --all | grep -i -E "merge|upstream|MR|!831" | head -5
git remote -v
```

- **预期**：12 个 patch 文件；上游 MR !831 的合并记录或对应提交可指出（gitee MR 页面的编号/标题）。
- **检查点**：能明确指认"哪 1–3 个 patch 已被上游合并"及凭证（MR 链接/合并提交）。这是 25 分项里最大的一块（4 分/个），凭证越硬越好；只有 1 个坐实 = 4 分，3 个坐实 = 12 分。

### S15 · Linux 行为基线对比（5 分项）

- **PDF 依据**：六(一)「与 Linux 行为基线的对比分析 5 分」。
- **本机执行**：

```bash
grep -r -l -i -E "linux 对照|对照结果|baseline|行为基线" report/*.md | head
grep -n -i -E "linux 对照" report/39-2026-09-30-初赛进度与后续计划.md | head -5
```

- **预期**：至少能找到"缺口现象在 Linux 上的正常行为 vs x-kernel 上的缺陷行为"的系统性对照（p0–p9 系列实施记录里应有逐项对照输出）。
- **检查点**：有专门章节/表格做 Linux 对照 = 5 分可争；只有零散句子 = 最多 2–3 分；完全没有 = 0 分。**这一项目前最虚**，回贴后若证据不足，我会给出补救写法（把散落的对照整理成一张"缺口-Linux 行为-x-kernel 行为"表）。

---

## 5. 阶段 M · 性能观测与量化方法（15 分）

> 均在 `evidence/2026-10-02_measure-single-perf3/` 核查。PDF 注意：初赛「不比较绝对性能结果」，评的是"测量方法与数据规范性"。

### S16 · ≥5 次中位数 + 原始数据 + 波动范围（3 分项）

- **PDF 依据**：七(二)4「每项指标重复不少于 5 次取中位数，提交原始数据与波动范围」。
- **执行**：

```bash
grep -E "samples|median|min|max" summary.json
wc -l raw.csv; head -3 raw.csv
```

- **预期**：5 个指标各 `samples: 5`，均给出 `median/min/max`；raw.csv 25 行数据 + 表头，每行带 evidence 路径。
- **检查点**：5 次✅、中位数✅、min/max（范围）✅、原始 CSV✅ = 3 分。

### S17 · 宿主机指纹（交叉核验材料）

- **PDF 依据**：七(二)4「注明宿主机 CPU 型号、内存、QEMU 版本与操作系统，供交叉核验」。
- **执行**：

```bash
cat host.txt
```

- **预期**：`Intel(R) Core(TM) i7-8665U`、内存 14.7 GiB、`QEMU emulator version 10.2.1`、Ubuntu 26.04、镜像/overlay 的 sha256。
- **检查点**：四项（CPU/内存/QEMU 版本/OS）齐 = 合规；缺一项扣该项核验分。

### S18 · 指标覆盖广度（4 分项）

- **PDF 依据**：六(一)「指标覆盖 4 分（覆盖 2 类 1 分、3 类 2 分、不少于 4 类 4 分，指标含启动时间、页面加载延迟、renderer 创建延迟、峰值内存、CPU 使用率等）」。
- **执行**：

```bash
cut -d, -f1 raw.csv | sort -u
ls ../2026-10-02_profile-single/
```

- **预期（现状）**：raw.csv 指标 = `single_gate`（门禁）、`single_first_navigation`（**启动时间类**）、`single_hold`（稳定性）、`first_passing_screendump`（**页面加载延迟类**）、`page_assertion`（判据）；profile 目录有 host QEMU 的 CPU/RSS 采样（**CPU/内存类的旁证**）。
- **检查点**：按 PDF 口径能站住的大类：启动时间、页面加载延迟、（host 观测的）CPU/内存 ≈ **3 类上下**；`renderer 创建延迟`单进程路线不适用（可注明），`峰值内存`目前只有 host QEMU RSS 1.67 GB（非 guest RSS，口径要写清）。预计 2 分；想够 4 分需要补 guest 侧内存/CPU 采样或明确把 host 观测计为一类——汇总时我给口径建议。

### S19 · 性能改善 before/after（3 分项，高危）

- **PDF 依据**：六(一)「性能改善数据 3 分（以队伍首个可运行版本为基线，任一指标相对改善 30% 及以上 3 分、15% 及以上 2 分、5% 及以上 1 分，无对比数据 0 分）」；七(二)1/3。
- **T490 上执行**：

```bash
cd ~/xk6 && ls evidence/ | grep -i -E "measure|baseline|before"
grep -r -l -E "baseline_median|improvement" evidence/ scripts/ 2>/dev/null | head -5
```

- **预期（现状）**：只有 `2026-10-02_measure-single-perf3` 单配置数据；**没有"首个可运行版本 vs 当前版本"的配对测量**。
- **检查点**：若无 before 序列（S5 的 tag 列表只有 `v0.1-single-initial` 一个），本项按 **0 分**登记。补救路径（汇总里给方案）：以 `v0.1-single-initial` tag 构建基线性 → 同一页面同一指标跑 ≥5 轮 → 与 perf3 配对，任一项改善 ≥5% 即可拿 1 分。工作量 = 一次构建 + 5 轮 ×5 min。

---

## 6. 阶段 D · 技术文档与代码规范（10 分）+ 材料六件套

### S20 · 设计报告结构完整（5 分项）

- **PDF 依据**：六(一)「设计报告结构完整 5 分」。
- **本机执行**：

```bash
ls docs/*.md report/3*.md report/4*.md | head -20
```

- **预期**：`docs/赛题六-前期准备清单与分阶段执行指南.md`、`docs/赛题六-基础任务操作手册.md` + report/39–47 系列已覆盖：背景与路线、实现、验证、缺口、性能、勘误。
- **检查点**：方案/实现/验证/结论四段式完整；有目录索引（report/42 即提交包索引）= 5 分可争。

### S21 · 关键代码与配置说明（5 分项）

- **PDF 依据**：六(一)「关键代码与配置说明详实 5 分」。
- **本机执行**：

```bash
ls report/patches/ | wc -l
head -30 scripts/t490/platform.env
```

- **预期**：17 个补丁文件（每个对应一类内核修复）+ `platform.env` 单一真源（QEMU 参数收敛一处，含 PDF 条款追溯注释）。
- **检查点**：补丁有命名与说明、配置有条款级注释 = 5 分可争。若补丁缺"前后效果"说明，汇总里列补强清单。

### S22 · 初赛材料六件套

- **PDF 依据**：六「参赛队伍提交技术方案文档、代码仓库、构建配置、自动化测试脚本、运行日志和演示视频等材料」。
- **执行**（本机+T490）：

```bash
# 本机
ls docs/ report/ | head -8; ls scripts/ | head -8
# T490
cd ~/x-kernel && git remote -v | head -2
find ~/x-kernel ~/xk6 -maxdepth 2 -iname "*.mp4" -o -maxdepth 2 -iname "*.mov" -o -maxdepth 2 -iname "*.mkv" 2>/dev/null | head
```

- **预期**：技术方案文档✅（S20）、代码仓库（x-kernel，remote 指向 gitee openkylin fork）✅、构建配置✅（defconfig+platform.env）、自动化测试脚本✅（scripts/ 全套）、运行日志✅（evidence/ console.log 等）——**演示视频大概率 ❌**（与 S23 联动）。
- **检查点**：六件套逐项打勾；录屏缺失登记为最高优先待办。

---

## 7. 阶段 Y · 演示效果（10 分）

### S23 · 完整流程录屏（6 分项，高危）

- **PDF 依据**：六(一)「完整流程录屏 6 分」。
- **执行**：S22 的 find 即本步检索动作；再补一次全盘确认：

```bash
# T490
find ~ -maxdepth 4 \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.webm" -o -iname "*.avi" \) 2>/dev/null | grep -v -E "\.cache|\.rustup|\.cargo" | head
```

- **预期（现状）**：未检索到录屏文件。
- **检查点**：有 = 核对内容完整（启动→Weston→Chromium→三页→输入→screendump 全流程，6 分）；无 = **0 分且属可快速补救项**——录制方案：S11 的 live boot 过程用宿主录屏工具录下（注意 PDF 规定录屏只作演示辅助、功能证据仍靠 screendump，两者不冲突），或把 10 张 screendump + 日志按时间轴剪成流程视频。建议录制时口播/字幕标注每步对应的 PDF 验收点。

### S24 · 现象与数据可复现（4 分项）

- **PDF 依据**：六(一)「现象与数据可复现 4 分」。
- **执行**：本步无新命令——`现象可复现` = S11 直播复现结果；`数据可复现` = raw.csv/summary.json + 测量脚本（`scripts/t490/measure-single-initial.sh`，交付物之一，复跑由评委/我们执行）。
- **检查点**：S11 通过 = 现象复现坐实（4 分全）；S11 跳过 = 证据仍可信但现场质询时被动，至多 2–3 分。

---

## 8. 回贴与汇总方式

1. 按 `S1 → S24` 顺序执行（S11/S23 可延后）；每步回贴「命令 + 完整输出」。
2. 我会对照本文件每步的"检查点"逐条核验，产出 `report/48-验证结果汇总.md`：按 PDF 六大评分项逐项列 PASS/FAIL/缺口 + 预估得分 + 差异说明 + 补救清单（按工作量排序）。
3. S12/S19/S23 是预判中的三大短板（场景覆盖登记、性能 before/after、录屏），其余步骤预期全绿。
