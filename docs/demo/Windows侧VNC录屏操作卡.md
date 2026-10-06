# Windows 侧 VNC 录屏操作卡（赛题六 · 完整流程录屏）

> 适用路线：`report/51` §路线 A —— QEMU 开 `-display vnc=192.168.1.217:0`，
> 在 **Windows 侧**同时看到「SSH 终端 + guest 画面」，一次录屏覆盖完整流程。
> 为什么选它：T490 不用装任何东西、不改当前会话，且画面是 QEMU 直出（非裁剪猜测）。

---

## 零、这套东西为什么能成立（已实测，2026-10-06）

| 验收点 | 实测结果 |
|---|---|
| 5900 端口监听 | ✅ `RFB 003.008` 版本串正常返回 |
| RFB 握手 | ✅ 安全类型 `[1]`（None），服务端名称 `QEMU` |
| 画面可取 | ✅ `scripts/vnc_grab.py` 成功抓到帧 |
| 分辨率跟随 guest | ✅ T+60 s 时 640×480（内核启动阶段，画面是 QEMU 的 `Display output is not active.`）；T+120 s 起变 1280×800 |
| screendump 通路 | ✅ 与 VNC **并存**，同轮 `screendumps 2 / 2 成功` |
| 平台合规 | ✅ `PASS=15 FAIL=0 → PLATFORM_COMPLIANT`（含 `-display vnc` 与 `-serial mon:stdio`） |

---

## 一、Windows 侧要装什么

| 软件 | 用途 | 获取 |
|---|---|---|
| **VNC Viewer** | 看 guest 画面 | RealVNC Viewer（免费个人版）或 TightVNC Viewer |
| **录屏软件** | 录整个屏幕 | Windows 自带 **Xbox Game Bar**（`Win+G`）最省事；要更好画质用 OBS Studio (Windows) |

> ⚠️ 不要用远程桌面（RDP）去连 T490 —— RDP 会独占显示器，且录不到 guest 的 VNC 画面。
> 我们的做法是：**SSH 终端 + VNC 窗口都开在你自己的 Windows 桌面上**，录的是 Windows 屏幕。

---

## 二、操作步骤

### 步骤 1 · 确认 T490 上的演示轮已起来

T490 侧（SSH 执行）：

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$PATH"
cd ~/xk6
python3 scripts/run-session.py \
  --cwd /home/mo/x-kernel \
  --make-args 'GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n' \
  --with-input \
  --qemu-args '-display vnc=192.168.1.217:0' \
  --duration 600 --interval 60 --first-shot 60 \
  --out /home/mo/xk6/evidence/<你的演示轮名>
```

**预期现象**：约 15–25 s 后开始刷内核启动日志；`ss -ltn | grep 5900` 能看到监听。

### 步骤 2 · Windows 连 VNC

```
VNC Viewer → 地址栏输入：192.168.1.217:5900 → 回车
```

**预期现象**：
- 前 1–2 分钟画面是黑底白字 `Display output is not active.`（内核启动、guest 还没激活显示）——**这是正常的**，不要以为坏了；
- 之后画面尺寸跳到 1280×800，出现图形会话与 Chromium 窗口。

### 步骤 3 · 开录屏

- `Win+G` → 点录制（或 OBS 开始录制）
- **先开录，再敲命令**，这样画面里有"敲命令"这一段

### 步骤 4 · 录制分镜（照着走，别漏拍）

| 顺序 | 画面里要出现什么 | 对应评分项 |
|---|---|---|
| 1 | SSH 终端里敲出完整的 `run-session.py` 命令 | 浏览器基础功能「完整运行命令」 |
| 2 | 内核启动日志滚动 | 图形环境启动 |
| 3 | VNC 画面从 `Display output is not active.` 变为图形会话 | 图形环境启动与稳定性 |
| 4 | guest 内启动 Chromium 的命令/日志 | 浏览器基础功能 |
| 5 | 官方 `index.html` 完整渲染 | 指定 HTML 渲染 10 分 |
| 6 | 键鼠交互（若本轮加载 `interaction.html`：点击后结论条变绿） | 键盘输入回显与鼠标点击跳转 |
| 7 | 稳定运行计时（**尽量拍到 ≥10 分钟**） | 连续稳定 10 分 |
| 8 | T490 上 `date` + `sha256sum …/kernel.bin` | 现象与数据可复现 4 分 |

### 步骤 5 · 收尾

- 停止录屏 → 产物约 **45 MB/分钟**（1080p30/x264/6 Mbps）
- 上传到 GitHub Release 附件（仓库当前已 374 MB，别再往 git 里塞视频）

---

## 三、安全须知

当前做法把 VNC 绑在 **T490 的局域网地址** `192.168.1.217:5900` 上，且**未设密码**。
同一局域网内任何人都能看到 guest 画面。录完请：

1. 立刻停掉 QEMU（`Ctrl-A x` 或跑完自动退出）；
2. 确认 `ss -ltn | grep 5900` 无输出。

**更安全的替代（延迟会升高，酌情使用）**：QEMU 改绑 `127.0.0.1:0`，Windows 侧走 SSH 隧道：

```bash
# QEMU 侧
--qemu-args '-display vnc=127.0.0.1:0'

# Windows 侧（另开一个终端，保持不关）
ssh -i C:/Users/12697/.ssh/id_ed25519_t490 -N -L 5900:127.0.0.1:5900 mo@192.168.1.217
# 然后 VNC Viewer 连 127.0.0.1:5900
```

---

## 四、怎么确认"没在录错东西"

Windows 侧可以直接用工具核验 VNC 画面（不必靠肉眼）：

```bash
python scripts/vnc_grab.py --host 192.168.1.217 --port 5900 --out tmp/vnc/check.png
# 预期：[OK] … 1280x800 … 非黑像素抽样 xx.x% -> 有内容
# 若输出「全黑」或提示 Display output is not active，说明 guest 还没画东西
```

工具见 `scripts/vnc_grab.py`（纯标准库实现的最小 RFB 客户端）。
