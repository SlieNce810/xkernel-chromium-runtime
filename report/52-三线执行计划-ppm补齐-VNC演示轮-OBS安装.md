# 三线执行计划与进度（ppm 补齐 / VNC 演示轮 / OBS 安装配置）

> 执行日期：2026-10-06
> 目标机器：T490 `mo@192.168.1.217`（Ubuntu 26.04.1 / GNOME 50.1 / QEMU 10.2.1）
> 前置依据：`report/49` §八（证据漏交）、`report/51`（录屏方案）

---

## 零、执行前的三项事实（已侦察，2026-10-06 14:40）

| 事实 | 值 | 意义 |
|---|---|---|
| T490 负载 | `load 0.00 0.00 0.00`，`pgrep -f qemu-system-aarch64` = 空 | ✅ 独占条件成立，可以起演示轮 |
| 内核 | `kernel.bin` 8348928 B，sha256 `7584653b…`，构建于 10-02 21:21；仓库 `2a1b101` **工作区干净** | ✅ 演示轮用的就是已归档的干净代码 |
| 镜像 | `disk.img` 2 GiB（10-05 18:58），`debugfs` 已确认 `/usr/share/html-test/` 含 `index.html` `interaction.html` `layout.html` | ✅ 演示轮可直接展示官方三页 |
| 脚本 | `~/xk6/scripts/run-session.py` 已有 `--qemu-args` / `--with-input` / `--first-shot` | ✅ 加 VNC 参数无需改脚本 |
| 本地 | **无 `rsync`**（Git Bash 缺）；有 `ssh` / `scp` / `tar` / `sha256sum` | ⚠️ 回传必须走 `tar` 管道或 `scp` |
| 其他 | 无 `flatpak`；`sudo` 需密码 | ⚠️ OBS 只能由你本人执行 sudo |

---

## 一、串行化矩阵（**最重要的一节**）

用户规则「严禁并发，所有外测串行」。三条线**逻辑上并行推进**，但凡触及 T490 的步骤必须排序：

| 步骤 | 触 T490？ | 是否独占 | 能否与其它步骤重叠 |
|---|---|---|---|
| L1-a 拉取 ppm | 只读 | 否（纯 IO） | 可与本地作业重叠，**不可与 L2 重叠**（抢 IO） |
| L1-b `git add -f` + commit | 否（纯本地） | — | 任何时候都可做 |
| L3-a `sudo apt install obs-studio` | 是 | **否，但吃 CPU/IO** | **严禁与 L2 重叠**（会拖慢并可能撕裂演示） |
| L3-b 验证 + 预置配置 | 是（只读） | 否 | 可与 L1-b 重叠 |
| L2-smoke VNC 冒烟（120 s） | 是 | **是** | 独占 |
| L2-full VNC 演示轮（600 s） | 是 | **是** | 独占 |

**最终串行顺序**：
```
L1-a  →  L2-smoke  →  L1-b  →  L2-full  →  L3-a(用户 sudo)  →  L3-b
```
> 把 `L3-a` 排到最后，是因为机器当前空闲，先把唯一需要"独占 + 安静"的 QEMU 演示轮跑完，
> 再让 apt 去占机器；否则 apt 解包会污染演示轮的节奏。

---

## 二、线 1 · 补齐 r19/r20/r21 的 screendump 并提交 commit

### 目标
把 T490 上完整、但被 `.gitignore` 静默漏挡的 screendump 补进仓库，使中阶任务
（键鼠交互、JS/CSS 布局）的关键功能证据在提交包里成立。

### 现状（已核对）
| 轮次 | T490 实有 | manifest 自述 | 仓库现有 | 待补 |
|---|---|---|---|---|
| `2026-10-02_t490-interaction-single-e2e-r19` | 5 | `5 / 5 成功` | 1 | **4** |
| `2026-10-02_t490-interaction-single-e2e-r20` | 5 | `5 / 5 成功` | 1 | **4** |
| `2026-10-02_t490-layout-e2e-r21` | 7 | `7 / 7 成功` | 2 | **5** |

### 步骤
| # | 动作 | 目标 | 依赖 |
|---|---|---|---|
| L1-a.1 | T490 侧对三个轮次的 `screenshots/*.ppm` 计算 sha256，落盘 | 得到校验基准 | 无 |
| L1-a.2 | `ssh 'tar cf - …' \| tar xf -` 回传（无 rsync，不用 scp 逐个） | 文件落到本地对应目录 | L1-a.1 |
| L1-a.3 | 本地重算 sha256，与 L1-a.1 逐文件比对 | 证明字节一致 | L1-a.2 |
| L1-b.1 | `git add -f`（**必须 -f**，被 ignore 的文件不加 -f 会被静默跳过） | 进入 index | L1-a.3 |
| L1-b.2 | `git status --short` 复核只有这三轮新增 | 防止误带无关文件 | L1-b.1 |
| L1-b.3 | `git commit`（中文信息，说明改了什么/为什么/验证） | 落库 | L1-b.2 |

### 验收标准
- **A1.1** 三个轮次在 `git ls-files` 中的 ppm 数 = 5 / 5 / 7；
- **A1.2** 本地 sha256 与 T490 计算值**逐文件一致**（不一致则中止，不得入库）；
- **A1.3** `git show --stat` 只显示这三轮的 ppm 新增，**没有别的文件**；
- **A1.4** 用 `scripts/evidence_ppm2mp4.py --realtime` 能对 r20 合出 >0 s 的视频（旁证帧序完整）。
- ⛔ **不做 `git push`**（用户规则：推送属外发动作，需单独确认）。

---

## 三、线 2 · 起一轮 VNC 演示轮

### 目标
产出一轮**带 VNC 画面输出**的演示轮，让 Windows 侧能通过 VNC 看到 guest 画面，
从而与终端同屏录屏，满足「完整流程录屏」；**同时不破坏 screendump 取证通路**。

### 关键未知（必须实测，不能假设）
1. `-display vnc=<LAN IP>:0` 与 xkmake 已有的 `-vga none -serial mon:stdio` 能否共存；
2. VNC 是否真的输出 virtio-gpu 的画面（`-vga none` 下设备是否被当作 primary）；
3. VNC 送进来的键鼠能否到达 `virtio-keyboard-pci` / `virtio-mouse-pci`。

### 步骤
| # | 动作 | 目标 | 依赖 |
|---|---|---|---|
| L2.0 | 在 T490 跑 `make justrun XKMAKE_ARGS=--dry-run` 复算字面命令行 | 确认 `-display vnc=…` 拼装正确、未被 xkmake 覆盖 | 无 |
| L2.1 | 用 `-display vnc=192.168.1.217:0` 起 **120 s 冒烟轮** | 端口 5900 开、screendump 通路未坏 | L2.0 |
| L2.2 | Windows 侧 `Test-NetConnection`/TCP 探测 5900 + 读 RFB 版本串 | 证明 VNC 服务存活 | L2.1 |
| L2.3 | 新增 `scripts/vnc_grab.py`（最小 RFB 客户端，raw 编码抓一帧存 PNG） | **用工具而非肉眼**验证 VNC 画面内容 | L2.1 |
| L2.4 | 用 `vnc_grab.py` 抓帧，与同轮 screendump 的 PNG 比对 | 证明 VNC 画面 = virtio-gpu 真实画面 | L2.3 |
| L2.5 | 起 **600 s 正式演示轮**（`--with-input`，interval 60） | 产出演示素材 + screendump | L2.4 |
| L2.6 | 校验该轮 screendump 是否渲染出官方 index 页 | 证明演示轮内容有效（不是黑屏走完） | L2.5 |
| L2.7 | 写出 Windows 侧操作卡（VNC Viewer + 录屏软件） | 你回去即可录 | L2.5 |

### 验收标准
- **A2.1** 冒烟轮中 `ss -ltnp | grep 5900` 有监听，且 Windows 侧能完成 RFB 握手；
- **A2.2** 冒烟轮中 screendump **仍然成功**（证明 VNC 与 `-serial mon:stdio` 不冲突）；
- **A2.3** `vnc_grab.py` 抓到的帧尺寸 = 1280×800 且**非全黑**；
- **A2.4** 演示轮 `manifest.txt` 的 `screendumps: N / N 成功`，且至少 1 张经 `ppm2png` 后
  肉眼可见官方 index 页（按 `report/26` 的判据）；
- **A2.5** 全程 TCG：命令行**不出现** `kvm` / `hvf`（复用 `t490_platform_check.sh` 断言）。
- ⚠️ 若 A2.3 失败（VNC 全黑），**如实记录为失败**并把演示轮退回「无头 screendump 合成」方案，
  不得调参掩盖。

---

## 四、线 3 · 安装配置 OBS Studio

### 目标
在 T490 上装好 OBS 32.1 并能通过 PipeWire/portal 录到 GNOME Wayland 桌面，
配合 `-display gtk` 的 QEMU 窗口，产出"Ubuntu 侧录屏"版本。

### 硬约束
- `sudo` **需要你本人输密码**，我无法代劳 → 这一步必须由你执行，我负责前后验证。
- portal 授权框弹在 T490**物理屏**上，必须有人在机器前点「共享」。
- 新增依赖：QEMU 需加 `-display gtk`（本轮不改归档命令行，另起演示轮）。

### 步骤
| # | 动作 | 目标 | 依赖 | 执行人 |
|---|---|---|---|---|
| L3.0 | 复核 apt 源与包版本、依赖可满足性 | 排除装到一半失败 | 无 | 我 |
| L3.1 | `sudo apt update && sudo apt install -y obs-studio` | 装上 | L3.0 | **你** |
| L3.2 | `obs --version`、`dpkg -l`、检查 portal/pipewire 插件 | 证明装成且具备 Wayland 采集能力 | L3.1 | 我 |
| L3.3 | 预置 `~/.config/obs-studio/global.ini`（录制路径、mkv、x264、1920×1080@30） | 开箱即有正确默认 | L3.2 | 我 |
| L3.4 | 写《OBS 配置与录制操作卡》（含 portal 授权、窗口捕获、分镜） | 你照着点即可 | L3.2 | 我 |
| L3.5 | 归档「OBS 路线下的 QEMU 启动命令」（加 `-display gtk`） | 演示轮与录制配套 | L3.2 | 我 |

> **不做**：不手工拼 OBS 场景集合 JSON。portal 来源**本来就必须交互授权**，
> 硬编码的 scene JSON 有版本不兼容风险，会把你的首次启动搞坏。

### 验收标准
- **A3.1** `obs --version` 输出含 `OBS Studio 32.1.0`；
- **A3.2** `dpkg -L obs-studio | grep -E 'obs-ffmpeg|linux-capture|pipewire'` 非空，
  证明 PipeWire 采集插件在；
- **A3.3** `global.ini` 被 OBS 接受（下次启动不重置、录制参数与文件一致）；
- **A3.4** 操作卡里的每条命令/点击都标了"预期现象"，可独立照做。

---

## 五、进度台账（执行后回填）

| 时间 | 线 | 步骤 | 结果 |
|---|---|---|---|
| 14:40 | — | 侦察 | ✅ T490 空闲（load 0.00、无 QEMU）；内核 `7584653b` / 树 `2a1b101` 干净；测试页已注入；本地无 rsync |
| 14:40 | — | 计划 | ✅ 本文件 |
| 14:41 | L1 | L1-a.1 sha256 基准 | ✅ T490 侧 17 行基准落盘 |
| 14:41 | L1 | L1-a.2 回传 | ✅ tar 管道 52 MB，17 张 ppm 全部解包 |
| 14:42 | L1 | L1-a.3 校验 | ✅ **17/17 sha256 与 T490 逐字节一致**（仓库原有 4 张比对亦一致） |
| 14:42 | L1 | L1-b 入库 + commit | ✅ `6b88d58`，13 个新增，`git show --stat` 无夹带 |
| 14:43 | L1 | A1.4 帧序 | ✅ r20 由 span=0 恢复为 5 帧/123.3 s；r21 为 7 帧/183.3 s；r20 末帧 PNG 可见「核心检查 6/6 全部通过」 |
| 14:43 | — | 文档/工具 commit | ✅ `fca83ef`（report/49、51、52 + `evidence_ppm2mp4.py` + memory） |
| 14:44 | L2 | L2.0 干跑 | ⚠️→✅ 首跑失败见 §七 问题 1；修正 PATH 后 **PASS=15 FAIL=0**，且 kernel.bin 哈希未变 |
| 14:45 | L2 | L2.1 冒烟轮 120 s | ✅ 5900 监听 + RFB `003.008` + `screendumps 2/2` + 合规 15/15 + 无 kvm/hvf |
| 14:46 | L2 | L2.3/L2.4 `vnc_grab.py` | ✅ 新增工具（纯标准库 RFB 客户端）；抓到 640×480（早期，QEMU 占位画面）→ 1280×800 |
| 14:48 | L2 | L2.5 正式演示轮 600 s | ✅ **`screendumps 10/10`**、合规 15/15；Chromium 142.0.7444.59 全程 `browser_alive=1` |
| 14:49~14:55 | L2 | L2.4 VNC 内容核验 | ✅ **A2.3 通过**：VNC 帧 1280×800、非黑像素 100%；画面即 guest 图形会话与官方 index 页 |
| 14:58 | L2 | 归档 | ✅ 10/10 sha256 一致；时延视频 20.08 s（`report/rendered-videos/`） |
| 14:59 | L2 | L2.7 操作卡 | ✅ `docs/demo/Windows侧VNC录屏操作卡.md` |
| 15:00 | L3 | L3.0 依赖复核 | ✅ apt 干跑：默认 108 包 / `--no-install-recommends` 67 包；源含 `obs-studio 32.1.0`；磁盘 354 GB |
| — | L3 | L3.1 `sudo apt install` | ⏸ **待你执行**（sudo 需密码，`sudo -n` 已确认不可用） |
| 15:00 | L3 | L3.4/L3.5 操作卡 + `-display gtk` 命令归档 | ✅ `docs/demo/OBS安装与配置操作卡.md` |
| — | L3 | L3.2/L3.3 验证 + 预置配置 | ⏸ 依赖 L3.1，装完后执行 |

### 验收状态汇总

| 线 | 验收点 | 状态 |
|---|---|---|
| L1 | A1.1 计数 5/5/7 | ✅ |
| L1 | A1.2 sha256 逐文件一致 | ✅ 17/17 |
| L1 | A1.3 `git show --stat` 无夹带 | ✅ |
| L1 | A1.4 帧序完整 | ✅ |
| L2 | A2.1 5900 监听 + RFB 握手 | ✅ |
| L2 | A2.2 screendump 通路未坏 | ✅ 2/2 与 10/10 |
| L2 | A2.3 VNC 帧 1280×800 非全黑 | ✅ 非黑 100% |
| L2 | A2.4 manifest N/N + 官方页可见 | ✅ 10/10，index 页已确认 |
| L2 | A2.5 无 kvm/hvf | ✅ PASS=15 FAIL=0 |
| L3 | A3.1~A3.4 | ⏸ 待 L3.1 完成后验证 |

---

## 七、执行中发现的问题（重要，均已定位）

### 问题 1 · 非交互 SSH 缺 `~/.cargo/bin` ⇒ 内核"编译不过"的假故障

现象：L2.0 干跑报 `QEMU 实际命令行抓取失败` + `PLATFORM_NOT_COMPLIANT`；
手工复算时 `make justrun` 编译失败：

```
error[E0658]: use of unstable library feature `cfg_select`
  --> /home/mo/x-kernel/mm/kaddr_layout/src/lib.rs:54:1
```

根因：**不是内核坏了，是 PATH**。非交互 SSH 的 PATH 里没有 `~/.cargo/bin`，
于是 `cargo`/`rustc` 解析到了系统自带的 **rustc 1.93.1**；
而 `~/x-kernel/rust-toolchain.toml` pin 的是 **channel = "1.95.0"**
（`cfg_select!` 需要更新版本才可用），rustup 装好的 1.95.0 根本没被用上。

修复：**T490 上任何触发构建/干跑的命令都必须先**
```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$PATH"
```
修正后 `rustc 1.95.0 (59807616e 2026-04-14)`，干跑 **PASS=15 FAIL=0**。

附带验证（很重要）：修正后重建，**kernel.bin 的 sha256 前后完全一致**
（`7584653b…`）⇒ 构建可复现，演示轮用的内核与归档证据是同一个。

### 问题 2 · `-f` 会把被忽略的文件一起加进来

`git add -f <dir>` 会**递归强制**暂存该目录下所有被 ignore 的文件。
本次 `git add -f evidence/<演示轮>` 把 10 张 ppm 一起暂存了。
这本身是本轮的**有意选择**（见下），但如果不想要，必须逐路径 `git add` 而非 `git add -f <dir>`。

### 演示轮 ppm 的入库策略（本轮决策，与 r19/r20/r21 不同）

- **r19/r20/r21**：ppm 是唯一认可的功能证据、且此前被漏交 ⇒ **全部入库**（`6b88d58`）。
- **本轮演示轮**：10 帧中 shot-03~shot-10 **哈希完全相同**（静态页无变化），
  但 screendump 是七(一)3 唯一认可的证据形式，为支撑 `manifest` 的 `10/10` 声明，
  **仍然全部入库（+30 MB）**，并附 `_ppm-sha256-t490-20261006.txt` 可独立校验。
  ⇒ 一致原则：**判据与演示轮的 screendump 都入库，只有纯诊断轮才留在 T490。**


---

## 六、风险与回退

| 风险 | 概率 | 影响 | 回退 |
|---|---|---|---|
| `-display vnc` 与 `-serial mon:stdio` 冲突 | 低 | 冒烟轮起不来 | 去掉 `-serial mon:stdio` 改用 monitor socket；或退回无头方案 |
| `-vga none` 下 VNC 黑屏 | 中 | VNC 路线不可用 | 演示轮改回 screendump 合成（`report/51` §路线 D），如实记录 |
| VNC 键鼠到不了 virtio-input | 中 | 无法用鼠标演示交互 | 用已有 QMP 输入驱动发事件，VNC 只当显示器 |
| apt 装 OBS 拉依赖失败 | 低 | 线 3 阻塞 | 降级 Kooha（更轻）；或改走 Windows 侧录屏 |
| 回传体积超预期 | 低 | 耗时 | 已确认仅 13 个 ppm ≈ 39 MB |
| QEMU 运行中 SSH 断连 | 低 | 演示轮中断 | 用 `run_in_background` 承载；中断即如实记录，不重启掩盖 |

> 全程遵守：**不重启、不中断、不重复启动**；失败的轮次原样保留为诊断依据，不覆盖。
