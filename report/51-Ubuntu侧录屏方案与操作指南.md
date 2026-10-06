# Ubuntu 侧录屏方案与操作指南（赛题六 · 演示视频）

> 目的：产出赛题六初赛「演示效果 10 分」中的 **完整流程录屏（6 分）**。
> 核对对象：**T490（Ubuntu 26.04.1 LTS / GNOME Shell 50.1）**，2026-10-06 实测环境。
> 关联：`report/49` §五 M1（演示视频缺失）是本指南要解决的缺口。

---

## 一、先分清三种"截图/录像"，别混用

赛题六 PDF 里出现三个不同的东西，用途不同、证据效力不同：

| 名称 | 出处 | 性质 | 能否当评分证据 |
|---|---|---|---|
| `screendump` 截图 | §七(一)3 | QEMU monitor 原生抓的 virtio-gpu 帧缓冲 | ✅ **功能类证据的唯一认可形式** |
| 主机屏幕录像（含本文的录屏） | §七(一)3 | 录宿主桌面 | ❌ 不作为验收依据；但**是"完整流程录屏 6 分"的必需材料** |
| 性能测量数据 | §七(二) | 宿主侧实测 | ✅ 性能项唯一依据 |

> 一句话：**录屏是给评委看"流程"的，不能替代 screendump 证据。两者都要有。**

---

## 二、T490 环境实测结论（决定了可选方案）

| 项目 | 实测结果 | 对方案的影响 |
|---|---|---|
| 系统 | Ubuntu 26.04.1 LTS (resolute), x86_64 | — |
| 桌面 | **GNOME Shell 50.1，纯 Wayland**（无 Xorg / 无 XWayland 进程） | ⛔ `ffmpeg -f x11grab` 不可用（没 X server） |
| 物理显示 | eDP-1 connected, **1920×1080**；DP/HDMI 全 disconnected | 只能录本机内屏 |
| 图形会话 | seat0 / tty2，用户 `mo`，自 2026-10-01 22:15 持续活跃 | 有真实桌面可录 |
| 已装录屏工具 | **一个都没有**（ffmpeg / OBS / Kooha / gnome-screenshot / scrot 全无） | 要么装，要么走 QEMU 侧 |
| GNOME 内置录屏 | ⛔ **已移除**：`gsettings get org.gnome.shell.keybindings toggle-recording` → "没有 toggle-recording 这个键"；`org.gnome.Shell.Screencast` D-Bus 接口也不存在 | `Ctrl+Alt+Shift+R` 这条路在 GNOME 50 上不存在 |
| portal 基础 | ✅ 齐全：`xdg-desktop-portal 1.21.1` / `-gnome 50.0` / `-gtk 1.15.3` / `pipewire 1.6.2` | OBS / Kooha 走 portal 录 Wayland **可行** |
| `sudo` | ❌ 需要密码（无免密） | 装软件必须你自己敲密码 |
| apt 源 | ✅ 正常（cn.archive.ubuntu.com, universe 已启用） | 见下表候选 |
| 磁盘 | `/` 354 GB 可用 | 充裕 |
| QEMU | 10.2.1（`/usr/bin` 与 `~/qemu-root/usr/bin` 同一版本） | — |
| QEMU 显示后端 | `none gtk sdl egl-headless curses spice-app dbus` + **`vnc` 可用**（`-display vnc=help` 可列出全部选项） | ✅ VNC 路线成立 |
| 当前 QEMU 起法 | **无 `-display`**（只有 `-vga none -serial mon:stdio`）→ 实际是 `none`，**没有 QEMU 窗口** | ⚠️ 桌面录屏本身录不到 guest 画面，必须先让 QEMU 出画面 |
| 免 root 通道 | ✅ python3（含 **Pillow 12.1.1**）、pip3、wget、curl、tar、xz、git；静态 ffmpeg 源可达 HTTP 200；`pip3 install --user imageio-ffmpeg` 可装 0.6.0 | ✅ 无 sudo 也能拿到 ffmpeg |

**apt 源里的录屏候选（已实测可装）**：

| 包 | 候选版本 | 备注 |
|---|---|---|
| `ffmpeg` | 7:8.0.1-3ubuntu2 | Wayland 下只能靠 screendump 序列，不能 x11grab |
| `obs-studio` | **32.1.0**-0ubuntu3 | 支持 PipeWire/portal 采集，Wayland 可用 ✅ |
| `kooha` | 2.3.1-6 | GNOME 风格，走 portal，轻量 ✅ |
| `vokoscreen-ng` | 4.4.0-1 | 主要面向 X11 |
| `simplescreenrecorder` | 0.4.4-7 | 主要面向 X11 |
| `byzanz` | 0.3.0+git20160312-6 | X11；输出 GIF |
| `gstreamer1.0-tools` | 1.28.2-1 | 已确认 `pipewiresrc` 元素可用，但 portal 协商仍需客户端 |
| `wf-recorder` | 0.6.0-1build1 | ⛔ **GNOME 不实现 wlr-screencopy，装了也用不了** |

---

## 三、路线对比与推荐

| # | 路线 | 需要 sudo | 录得到"流程"吗 | 与赛题契合度 | 推荐 |
|---|---|---|---|---|---|
| **A** | QEMU `-display vnc` → **在 Windows 侧录屏** | ❌ 不需要 | ✅ 终端 + QEMU 画面同屏 | 高 | ★★★ **首选** |
| **B** | 装 **OBS Studio 32.1** 录 GNOME Wayland 桌面 | ✅ 需要 | ✅ 全桌面 | 高 | ★★☆ 要"Ubuntu 下录屏"字面效果时 |
| **C** | 装 **Kooha** 录 GNOME Wayland 桌面 | ✅ 需要 | ✅ 全桌面 | 高 | ★★☆ 比 OBS 简单 |
| **D** | **screendump 序列 → ffmpeg 合成**（无头，与判据同源） | ❌ 不需要 | ⚠️ 只有 guest 画面 | 中（可复现性最强） | ★★☆ 兜底 / 补充素材 |
| E | 切 "Ubuntu on Xorg" 会话 + `ffmpeg -f x11grab` | ✅ 需要 | ✅ 全桌面 | 中 | ✗ 会打断当前会话 |
| ✗ | GNOME 内置 `Ctrl+Alt+Shift+R` | — | — | — | **GNOME 50 已移除，不存在** |
| ✗ | `wf-recorder` | — | — | — | **GNOME 上不可用** |

> **为什么首选 A**：T490 一行不改、一个包不装、当前会话不受影响；而"完整流程"恰好就是
> 「Windows 终端里敲命令 → QEMU 画面起来 → Chromium 显示页面 → 交互」，
> 在 Windows 侧一个屏幕录制里天然全部拍到。

---

## 四、各路线操作步骤

### 路线 A · QEMU VNC + Windows 侧录屏（推荐）

**① 让 QEMU 把画面送出来**（T490 侧，只加一个参数，不改其它任何参数）

`run-session.py` 已内建 `--qemu-args`，无需手工拼完整命令行：

```bash
cd ~/xk6
python3 scripts/run-session.py \
  --cwd /home/mo/x-kernel \
  --make-args 'GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n' \
  --with-input \
  --qemu-args '-display vnc=192.168.1.217:0' \
  --duration 540 --interval 60 --first-shot 90 \
  --out /home/mo/xk6/evidence/<新轮次名>
```

要点：
- `-display vnc=<监听地址>:0` → 端口 **5900**。写 T490 的 LAN IP 而不是 `0.0.0.0`，避免暴露到全网。
- `-serial mon:stdio` 仍然保留 ⇒ **VNC 与 screendump 取证可并存**，同一轮次既出演示画面又出合规证据。
- 这一轮是**演示轮**，建议目录名带 `demo` 后缀，与判据轮区分开；判据轮仍用原来的无头命令行。
- ⚠️ 待实测确认：VNC 送进来的键鼠事件能否到达 `virtio-keyboard-pci` / `virtio-mouse-pci`。
  若不能，改用你已有的 **QMP 输入驱动**脚本发事件（`scripts/t490/` 下的 qmp 系列），
  VNC 只当显示器用。

**② Windows 侧**

```
1. RealVNC Viewer / TigerVNC 连 192.168.1.217:5900  → 看到 guest 画面
2. 同时开一个 SSH 终端（跑 run-session.py 的那个）
3. 用 OBS(Windows) 或 Xbox Game Bar（Win+G）录整个屏幕
4. 录制顺序：先开录 → 再敲启动命令 → QEMU 起 → 图形会话 → Chromium → 页面 → 交互 → 停止录制
```

**优点**：零 T490 变更、画面是 QEMU 直出、天然覆盖"完整流程"。

---

### 路线 B · OBS Studio 录 GNOME Wayland 桌面

```bash
# 1) 装（需要你自己输密码）
sudo apt update
sudo apt install -y obs-studio

# 2) 让 QEMU 出窗口（关键！否则桌面录屏里没有 guest 画面）
#    在 make/qemu 参数里加 -display gtk
python3 scripts/run-session.py --cwd /home/mo/x-kernel \
  --make-args 'GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n' --with-input \
  --qemu-args '-display gtk' \
  --duration 540 --interval 60 --out /home/mo/xk6/evidence/<演示轮>

# 3) 启动 OBS
obs
```

OBS 内配置：
1. 来源 → `+` → **屏幕采集（PipeWire）** → 选「屏幕」或「窗口」
2. 第一次会弹 **portal 授权框**，出现在 **T490 的物理屏**上 → 点「共享」
   ⚠️ 所以这条路**必须有人在 T490 前面**；纯 SSH 远程无法完成授权
3. 设置 → 输出 → 录像：封装 `mkv`（防崩溃丢文件）、编码器 `x264`、码率 `6-8 Mbps`
4. 设置 → 视频：基准/输出分辨率 `1920x1080`，FPS `30`

---

### 路线 C · Kooha（最轻量的 Wayland 录屏）

```bash
sudo apt install -y kooha
kooha
# 选「录屏」→ 选显示器/窗口 → 延迟 3s → 录制
# 同样会弹 portal 授权框，需在 T490 物理屏上确认
```
产物默认落在 `~/Videos/`。适合只需要一段干净录屏、不想开 OBS 的场景。

---

### 路线 D · screendump 序列 → 视频（无头，不需要 sudo）

这条路的工具已经做好并**实测通过**：`scripts/evidence_ppm2mp4.py`。

**① 取 ffmpeg（三选一，都不需要 root）**

```bash
# A) 静态二进制
mkdir -p ~/bin && cd ~/bin
wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
tar xf ffmpeg-release-amd64-static.tar.xz --strip-components=1 --wildcards '*/ffmpeg' '*/ffprobe'
export PATH="$HOME/bin:$PATH"

# B) 借 Python 包捆绑的静态 ffmpeg（脚本会自动发现，无需改 PATH）
pip3 install --user imageio-ffmpeg

# C) 有 sudo 时
sudo apt install -y ffmpeg
```

**② 合成**

```bash
# 均匀 2 fps（帧间隔小的轮次，最像录像）
python3 scripts/evidence_ppm2mp4.py \
  --evidence-dir evidence/2026-10-02_t490-single-initial-r5 --fps 2

# 按 timestamps.csv 的真实间隔播放并加速 20 倍（interval=60 的稀疏轮次）
python3 scripts/evidence_ppm2mp4.py \
  --evidence-dir evidence/2026-10-02_t490-single-initial-r5 --realtime --speed 20

# 只看帧表不编码
python3 scripts/evidence_ppm2mp4.py --evidence-dir <轮次> --realtime --dry-run
```

产物默认写到 `report/rendered-videos/<轮次名>.mp4`（**故意不写进 `evidence/`**，
因为 AGENTS.md 规定证据包不可变，合成视频是派生产物）。

**③ 采集密度上限（重要）**

`run-session.py` 的 `screendump()` 每次要 ~3.2 s（Ctrl-A c 切 monitor → `screendump`
→ 切回，中间是固定 sleep），所以 **`--interval` 实际最低约 3.5 s，上限约 0.3 fps**。
它做不出真录像，只能做"有真实时间戳的幻灯片"。否则用 `--realtime` 保证节奏不乱。

---

### 路线 E · 切 X11 会话 + `ffmpeg -f x11grab`（不推荐）

```
注销 → 登录界面右下角齿轮 → 选 "Ubuntu on Xorg" → 登录
ffmpeg -y -f x11grab -framerate 30 -video_size 1920x1080 -i :0.0 \
       -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p demo.mp4
（停止：按 q）
```
**代价**：会关闭当前 GNOME 会话（正在跑的 QEMU 会被带走）。只有在"必须用 x11grab"时才走这条。

---

## 五、录屏脚本化：先写"分镜"

不管走哪条路，建议把要录的内容先写成固定步骤，避免录完发现漏拍。赛题"完整流程"至少覆盖：

| # | 画面内容 | 对应的评分项 |
|---|---|---|
| 1 | 终端里敲启动命令（含完整 QEMU 参数） | 浏览器基础功能「完整运行命令」 |
| 2 | QEMU 启动、内核日志滚动 | 图形环境启动 |
| 3 | 图形会话建立（Weston / 合成器起来） | 图形环境启动与稳定性 |
| 4 | 启动 Chromium 的命令 | 浏览器基础功能 |
| 5 | 官方 `index.html` 正确渲染 | 指定 HTML 渲染 10 分 |
| 6 | 键鼠交互（点击后结论条变色） | 键盘输入回显与鼠标点击跳转 |
| 7 | 稳定运行计时（≥10 min，最好拍到 `SINGLE_GATE=1`） | 连续稳定 10 分 |
| 8 | 宿主 `date` + 内核指纹（`sha256sum kernel.bin`） | 现象与数据可复现 4 分 |

建议在录制时**把 `date` 显示在画面里**（或录屏工具开时间水印），便于与 `evidence/` 对齐。

---

## 六、产物归档建议

- 体积：1080p30 / x264 / 6 Mbps ≈ **45 MB/分钟**；10 分钟约 450 MB。
  **不要直接 commit 进 GitHub**（仓库当前 374 MB，再加会很大）。
- 推荐：走 **GitHub Release 附件**（与 `agentos-disk.img.xz` 同通道），
  在根 `README.md` 里给出下载链接。Release 附件单文件上限 2 GB，足够。
- 同时在 `docs/demo/` 放：`录屏说明.md`（录像时间、对应轮次、复现命令）。

---

## 七、本次实测踩到的坑（都已复核）

| # | 坑 | 实测证据 | 结论 |
|---|---|---|---|
| 1 | GNOME 50 内置录屏已移除 | `gsettings get … toggle-recording` → 键不存在；`org.gnome.Shell.Screencast` introspect 无 Screencast 接口 | 不要再教 `Ctrl+Alt+Shift+R` |
| 2 | 纯 Wayland 下 `x11grab` 不可用 | `ps -eo comm \| grep Xorg` 空 | 想用 x11grab 必须切 Xorg 会话 |
| 3 | `wf-recorder` 在 GNOME 上无效 | GNOME 不实现 wlr-screencopy | 别装 |
| 4 | **当前 QEMU 无窗口** | `cmd.txt` 里无 `-display`，只有 `-vga none -serial mon:stdio` | 桌面录屏前必须先加 `-display gtk` / `vnc` |
| 5 | `-r 25 -fps_mode cfr` 合成会**系统性膨胀** | 计划 9.015 s → 实际 11.96 s（+33%）；量化到 25 fps 网格后仍是 11.96 s；改 `-fps_mode passthrough` → 9.04 s ✅ | `evidence_ppm2mp4.py` 已固定用 passthrough |
| 6 | Pillow `load_default()` 不含 CJK 字形 | 烧中文会出豆腐块 | 脚本的烧字文本只用 ASCII，找不到 CJK 字体时自动剥离并告警 |
| 7 | 托管 Python 环境跨平台差异 | Windows 上 `PIL.ImageText` 报 `'tuple' object has no attribute 'getbbox'`（`load_font` 返回元组未解包） | 已修；脚本三种模式在 r5 真实数据上全部跑通 |

---

## 八、⚠️ 顺带发现的提交级问题：关键 screendump 漏交

核对录屏素材时发现：**r19 / r20 / r21 的 screendump 在 T490 上完整，但归档到仓库的只有少数几张。**

| 轮次 | T490 `~/xk6/evidence` 实有 | manifest 自述 | 仓库/本地归档 | 缺失 |
|---|---|---|---|---|
| `2026-10-02_t490-interaction-single-e2e-r19` | 5 张（120/150/180/210/final s） | `5 / 5 成功` | **1 张**（`shot-03-at0180s`） | 4 |
| `2026-10-02_t490-interaction-single-e2e-r20` | 5 张 | `5 / 5 成功` | **1 张**（`shot-05-final`） | 4 |
| `2026-10-02_t490-layout-e2e-r21` | 7 张 | `7 / 7 成功` | **2 张**（`shot-03`、`shot-07-final`） | 5 |
| `2026-10-02_t490-single-initial-r5` | 10 张 | `10 / 10 成功` | 10 张 ✅ | 0 |

**根因**：`.gitignore` 的 `evidence/**/*.ppm` 对**未跟踪**文件生效，
新产生的 ppm 在 `git add` 时被静默跳过；而 r5 的 10 张是规则生效**之前**就已入库的，
所以"看起来正常"，掩盖了问题。这正是 `report/49` §六 那条口径矛盾的实质后果 ——
**不是"多存了冗余"，而是"关键证据被漏交"**（评分表：缺证据按项计 0 分）。

**修复（T490 与仓库各一步）**：

```bash
# ① T490 → 归档：补齐被漏掉的 screendump（这些是 §七(一)3 唯一认可的功能证据）
cd ~/xk6
for d in 2026-10-02_t490-interaction-single-e2e-r19 \
         2026-10-02_t490-interaction-single-e2e-r20 \
         2026-10-02_t490-layout-e2e-r21 ; do
  rsync -a --include='*/' --include='*.ppm' --exclude='*' \
        "evidence/$d/screenshots/" "本机中转目录/$d/screenshots/"
done

# ② 本机入库：ppm 已被 ignore，必须显式 -f 强制加入
git add -f evidence/2026-10-02_t490-interaction-single-e2e-r19/screenshots/*.ppm
git add -f evidence/2026-10-02_t490-interaction-single-e2e-r20/screenshots/*.ppm
git add -f evidence/2026-10-02_t490-layout-e2e-r21/screenshots/*.ppm
git commit -m "fix(evidence): 补齐 r19/r20/r21 被 .gitignore 误挡的 screendump"
```

> 顺带建议：既然 ppm 是 §七(一)3 唯一认可的证据形式，`.gitignore` 排除全部 ppm 的
> 策略本身就值得重新评估 —— 至少对**判据轮次**的 screendump 应当强制入库，
> 只对诊断轮次做排除。
