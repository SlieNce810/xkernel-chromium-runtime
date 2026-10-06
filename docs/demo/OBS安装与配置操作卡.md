# OBS Studio 安装与配置操作卡（T490 · GNOME 50.1 Wayland）

> 目的：在 T490 上录「Ubuntu 桌面 + QEMU 窗口」版本的演示视频，作为 `report/51` §路线 B。
> 前置：`report/51` 已实测 —— T490 是 **GNOME Shell 50.1 纯 Wayland**，**没有** Xorg，
> 所以 `ffmpeg -f x11grab` 不可用；但 **xdg-desktop-portal / -gnome / pipewire 全部已装**，
> 走 portal 采集是可行的。

---

## 一、为什么必须装第三方（不能指望内置）

| 你以为可以的 | 实测结论 |
|---|---|
| GNOME 内置录屏 `Ctrl+Alt+Shift+R` | ⛔ **GNOME 50 已移除**：`gsettings get org.gnome.shell.keybindings toggle-recording` 报"没有这个键"；`org.gnome.Shell.Screencast` D-Bus 接口也不存在 |
| `ffmpeg -f x11grab` | ⛔ 没有 X server（`ps -eo comm \| grep Xorg` 为空） |
| `wf-recorder` | ⛔ GNOME 不实现 wlr-screencopy |
| **OBS / Kooha（走 portal）** | ✅ 可行 |
| **screendump 序列合成** | ✅ 可行（`scripts/evidence_ppm2mp4.py`，见 `report/51` §路线 D） |

---

## 二、安装（**需要你本人执行 sudo**）

```bash
sudo apt update
sudo apt install -y obs-studio
```

**已实测的依赖情况**（`apt-get install -s` 干跑，2026-10-06）：

| 模式 | 新装包数 | 说明 |
|---|---|---|
| 默认 `apt install obs-studio` | **108 个**（含 VLC 套件，供媒体源） | ✅ **推荐**，不会缺插件 |
| `--no-install-recommends` | 67 个 | 更省流量，但少媒体源相关组件 |

候选版本：`obs-studio 32.1.0-0ubuntu3`（universe，已确认源里有）。
磁盘：`/` 354 GB 可用，无压力。

**装完成功**（2026-10-06 实测，用户执行 sudo 后由本机 SSH 验证）：

| 验收点 | 实测结果 |
|---|---|
| A3.1 版本 | ✅ `/usr/bin/obs` → **`OBS Studio - 32.1.0-0ubuntu3`** |
| A3.2 包状态 | ✅ `obs-studio` / `obs-plugins` / `libobs0t64` 均为 `32.1.0-0ubuntu3` |
| A3.2 采集插件 | ✅ `/usr/lib/x86_64-linux-gnu/obs-plugins/` 含 **`linux-pipewire.so`**（Wayland 采集路径）与 **`linux-capture.so`** |
| A3.2 编码器 | ✅ `obs-x264.so` 存在；`libx264-165` 已装 |
| 录制目录 | ✅ 已创建 `~/Videos` |
| 首启目录 | ✅ `~/.config/obs-studio/basic/{profiles,scenes}` 已生成 |

插件全清单（供核对）：`decklink*` `frontend-tools` `image-source` `linux-alsa` `linux-capture`
`linux-jack` `linux-pipewire` `linux-pulseaudio` `linux-v4l2` `obs-ffmpeg` `obs-filters` `obs-nvenc`
`obs-outputs` `obs-transitions` `obs-websocket` `obs-x264` `rtmp-services` `text-freetype2` `vlc-video`

---

## 二·补 · ⚠️ 为什么没有"预置好的配置"（重要，勿以为是漏做）

**结论：OBS 的 profile 配置无法在无显示器环境下生成或校验，因此本卡不预置 `basic.ini`，改为"照点"流程。**

实测依据：

1. `QT_QPA_PLATFORM=offscreen obs --disable-shutdown-check` 能启动，但日志只有一行关键错误
   —— **`Unable to open X display`**，`Loading module` 行数 = **0**（插件一个都没加载）；
2. 结果只生成了空 `global.ini`、两行 `user.ini` 与空的 `basic/{profiles,scenes}` 目录，
   **没有 profile、没有 `basic.ini`**；
3. 换成 `xvfb-run` 可以解决，但 T490 **未装 Xvfb**（源里有 `xvfb 2:21.1.22-1ubuntu1.2`，装它需要再一次 sudo）。

**为什么不直接手写 `basic.ini`**：配置键名必须对得上 OBS 32 的真实实现，猜错会让首次启动带上错误默认值。
用 `strings /usr/bin/obs` 只能确认一部分键（见 §附），**`Profile` / `SceneCollection` / 录制格式值均未确认**
—— 所以按"不伪造完成度"原则**不写**。

### 收尾只差两步（都在你面前做，各 1 分钟）

```
第 1 步：在 T490 桌面启动一次 OBS        → 它会写出真实的 basic.ini 与场景集合
第 2 步：按 §四 的两张表把设置点一遍     → 或把这步交给我：我读真实的 basic.ini 再改值，零猜测
```

> 第 1 步本来就必须做 —— portal 屏幕共享授权框弹在 T490 物理屏上，纯 SSH 完不成。

---

## 三、首次启动与 portal 授权（**必须在 T490 物理屏前操作**）

```bash
obs
```

⚠️ **这一步纯 SSH 远程做不了**：OBS 请求屏幕采集时，GNOME 会弹一个
「屏幕共享」授权对话框，**它出现在 T490 自己的屏幕上**，必须有人点「共享」。

首次启动向导可以全部跳过（我们手动配）。

---

## 四、配置（照点即可）

### 4.1 添加采集源

```
来源 面板 → 点 "+" → 选「屏幕采集(PipeWire)」
  → 名称填 screen → 确定
  → 弹出 GNOME 屏幕共享对话框 → 选「屏幕」或具体窗口 → 点「共享」
```

- 选 **「屏幕」**：录整个桌面（能看到终端 + QEMU 窗口 + 一切）；
- 选 **「窗口」**：只录一个窗口。**注意**：一次 portal 授权只能对应一个捕获源，
  所以"终端 + guest 画面"同框必须选「屏幕」。

### 4.2 输出设置（设置 → 输出，输出模式选「高级」）

| 项 | 值 | 理由 |
|---|---|---|
| 录像路径 | `/home/mo/Videos`（先 `mkdir -p ~/Videos`） | 默认目录不存在 |
| 录像格式 | **`mkv`** | 崩溃/断电时 mkv 不会整段报废；录完再「重新封装录像」转 mp4 |
| 视频编码器 | `x264` | TCG 跑 QEMU 已经吃满 CPU，软件编码最稳 |
| 码率控制 | `CBR`，码率 `6000` Kbps | 1080p30 约 45 MB/分钟 |
| 音频 | 关掉（演示不需要，少一路出错源）`设置 → 音频 → 全局音频设备 → 桌面音频：已禁用` | — |

### 4.3 视频设置（设置 → 视频）

| 项 | 值 |
|---|---|
| 基准(画布)分辨率 | `1920x1080` |
| 输出(缩放)分辨率 | `1920x1080` |
| 常用 FPS 值 | `30` |

> T490 内屏实测就是 1920×1080（`cat /sys/class/drm/card1-eDP-1/modes | head -1`）。

---

## 五、配套：让 QEMU 出窗口（否则录屏里没有 guest 画面）

⚠️ **当前 QEMU 是无头跑的**（命令行只有 `-vga none -serial mon:stdio`，没有 `-display`），
所以直接录桌面只会录到空桌面 + 终端。要看到 Weston/Chromium，必须加 `-display gtk`：

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$PATH"
cd ~/xk6
python3 scripts/run-session.py \
  --cwd /home/mo/x-kernel \
  --make-args 'GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n' \
  --with-input \
  --qemu-args '-display gtk' \
  --duration 600 --interval 60 --first-shot 60 \
  --out /home/mo/xk6/evidence/<演示轮名>-gtk
```

- `-display gtk` **不影响**赛题合规：断言只禁 `kvm`/`hvf`（已实测 `-display vnc` 时
  `PASS=15 FAIL=0`，加入 `-display gtk` 同理）。
- ⚠️ **但这一轮不能当判据轮**：命令行与归档的无头轮不同。请另起目录名（带 `-gtk` 后缀），
  判据仍用无头轮的 screendump。
- 若要同时保留 screendump 通路，`-serial mon:stdio` 不能去掉。

---

## 六、录制分镜（与 VNC 路线共用）

| 顺序 | 画面 | 对应评分项 |
|---|---|---|
| 1 | 终端敲启动命令（完整参数） | 「完整运行命令」 |
| 2 | QEMU 窗口出现 + 内核日志滚动 | 图形环境启动 |
| 3 | guest 图形会话起来 | 图形环境启动与稳定性 |
| 4 | Chromium 窗口出现 | 浏览器基础功能 |
| 5 | 官方 `index.html` 完整渲染 | 指定 HTML 渲染 10 分 |
| 6 | 键鼠交互 | 键盘回显与鼠标点击跳转 |
| 7 | 稳定运行计时（尽量 ≥10 min） | 连续稳定 10 分 |
| 8 | `date` + `sha256sum …/kernel.bin` | 现象与数据可复现 4 分 |

**已实测的 guest 时间线**（来自 `2026-10-06_t490-vnc-demo` 的 `console.log`，可用来卡录制节奏）：

| guest 时刻 | 现象 |
|---|---|
| T+0 s | `[autostart] launching /root/autorun.sh` |
| T+0 s | `[single] chromium=Chromium 142.0.7444.59`，`WESTON_SOCKET=wayland-1` |
| **T+60 s** | `browser_alive=1 weston_alive=1 navigation=1` —— **页面已提交** |
| T+180 s 起 | 画面稳定为官方 index 页（screendump 哈希恒定） |

> 也就是说：**前 60 秒是黑屏/桌面**，真正出画面在 **T+60 s ~ T+180 s**。
> 录屏时把这段录进去，正好展示"从启动到出画面"的完整过程。

---

## 七、验收标准

| # | 验收点 | 判定方式 | 状态 |
|---|---|---|---|
| A3.1 | `obs --version` 含 `OBS Studio 32.1.0` | 命令输出 | ✅ **已通过**（实测 `OBS Studio - 32.1.0-0ubuntu3`） |
| A3.2 | `obs-studio`/`obs-plugins`/`libobs` 为 `ii`，插件目录含 `linux-capture` 与 `linux-pipewire` | `dpkg -l` + `ls` | ✅ **已通过** |
| A3.3 | OBS 能列出并选中「屏幕采集(PipeWire)」源，且授权后预览出画面 | OBS 界面 | ⏸ 待你在物理屏前完成（§三/§四） |
| A3.4 | 录一段 10 s 测试片，`ffprobe` 显示 1920x1080 / 30fps / h264 | `ffprobe` | ⏸ 同上 |

> A3.1/A3.2 是本机 SSH 可验证的部分，已实测达标；
> A3.3/A3.4 依赖物理屏上的 portal 授权，**纯 SSH 不可能完成**，故留给你。

---

## 八、常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 「屏幕采集」源里没有 PipeWire 选项 | 装的是旧版/精简版缺插件 | 改 `sudo apt install --reinstall obs-studio` 走默认（含 recommends） |
| 预览全黑 | 选中的是「窗口」但窗口最小化；或授权没给 | 重新选「屏幕」，重走授权 |
| 录制有画面但没声音 | 本就关了桌面音频 | 演示不需要声音，忽略 |
| 录完 mkv 要交 mp4 | 赛题评审更认 mp4 | OBS「文件 → 重新封装录像」 |
| 录屏卡顿、掉帧 | TCG 已吃满 CPU | 降 FPS 到 24、码率到 4000，或改用 `report/51` §路线 A（VNC + Windows 侧录） |

---

## 附 · 若要手工编辑 `basic.ini`：已核实的键名（**部分**，勿全信）

以下键名由 `strings -n 4 /usr/bin/obs | grep -cx <key>` 在 **本机 32.1.0 二进制**上确认为存在，
可作为手工编辑的起点；**未列出的键未经核实，不要照抄网上的旧教程**：

| 已确认存在的键 | 备注 |
|---|---|
| `RecFormat2` | ⚠️ **现代 OBS 用 `RecFormat2`，不是 `RecFormat`**（后者在本机二进制中**不存在**） |
| `RecFilePath` / `RecRB` / `RecRBTime` / `RecSplitFile` / `RecSplitFileTime` | 录制路径与自动分段 |
| `BaseCX` / `BaseCY` / `OutputCX` / `OutputCY` / `ScaleType` | 视频设置 |
| `FPSCommon` / `FPSNum` / `FPSDen` / `FPSInt` / `FPSType` | 帧率（常用值走 `FPSCommon`） |
| `StreamEncoder` | 编码器（录制侧对应的键**未确认**） |
| 段名 `SimpleOutput` / `AdvOut` | 输出模式两套段 |
| 编码器 id **`obs_x264`** | ⚠️ 不是 `x264`（后者在本机二进制中**不存在**） |
| 全局键 `FirstRun` / `ProfileDir` / `SceneCollectionFile` | ⚠️ `Profile` / `SceneCollection` **未确认** |

> 建议：与其手改 ini，不如按 §三/§四**点一遍界面**（约 8 个字段），
> 或让 OBS 先跑一次、再由我读它的真实 `basic.ini` 改值。
