# 27 · X11 启动链修复 + 官方测试页实测：定位到内核 DRM 的 24bpp 缺口

> 日期：2026-09-22 ｜ 机器：**T490**（Ubuntu 26.04，i7-8665U，QEMU 10.2.1，纯 TCG）
> guest：**agentos kiosk 镜像**（Alpine 3.22 + Xorg 1.21.1.19 + jwm + chromium）
> 平台：`2g / 4 vCPU / -cpu cortex-a76 / 无 -accel`（由 `platform.env` 单一真源控制）
> 输入：`report/25`（X11 冒烟失败 + 两条已定位阻塞）、`report/26`（官方三页套）
> 结论：**X11 启动链已修复并自证；官方三页注入链已在 T490 落地并通过干跑 19/19；
> 三轮官方页实测把图形阻塞从"启动脚本层"推进到"内核 DRM 层"，并取得了
> errno 级证据：`DRM_IOCTL_MODE_CREATE_DUMB` 只接受 32bpp，而 Xorg 的 modesetting
> 在 ShadowFB 被强制开启时申请的是 24bpp 硬件前缓冲。**

---

## 1. 结论先行

| # | 事项 | 状态 | 关键证据 |
|---|---|---|---|
| 1 | x-kernel 不执行 `/etc/inittab` → 新增**跨镜像通用**的 autostart 钩子注入 | ✅ 修复 | `[autostart] hook fired` / `launching /root/autorun.sh`（console.log:96-97） |
| 2 | 镜像自带 `x11-session` 把 Xorg 日志重定向到 `/dev/ttyAMA0`（必失败） | ✅ 绕过 | 改用 `-logfile /root/xorg.log`，Xorg 日志首次完整落盘 |
| 3 | 官方三页 + 注入器在 T490 落地 | ✅ | 远端 `scripts/testpage/` 三页 sha256 与本地一致；干跑 **19/19** |
| 4 | 三轮官方页实测（`index.html`） | ⚠️ 无图形证据 | 3 轮 × 各自独立证据目录，`严格集未通过 = 全部`、`心跳 0/N` |
| 5 | 阻塞点从"启动链"推进到"内核 DRM" | ✅ | 三轮 Xorg 日志一致：`Using 24bpp hw front buffer` → `AddScreen/ScreenInit failed` |
| 6 | `CREATE_DUMB` 的 bpp 约束（errno 级） | ✅ 已测量 | `drmdumbprobe`：bpp=32 通 / bpp=24·16 → **EINVAL(22)** |
| 7 | 用户态是否还有出路 | ❌ 已穷尽 | `ShadowFB=false` + `AccelMethod=none` 被 `enabled FORCE` 覆盖 |
| 8 | 因果闭环（24bpp 被拒 ⇒ ScreenInit 失败） | ⏳ **待干预性验证** | Xorg 未打出点名 CreateDumb 的 (EE) 行，见 §7.2 |

---

## 2. 启动链修复：三处缺陷、两处是"沉默失败"

### 2.1 缺陷 1：`/root/autorun.sh` 从来没被拉起来（**本轮最重要的一处修复**）

`t490_round.sh` 的文件头写着契约：「`<autorun文件名>` 注入为 `/root/autorun.sh`
（guest 的 99-autostart 会调它）」。但这条契约在 **agentos 官方 kiosk 镜像上不成立**：

```text
/etc/profile.d/ 实测内容：20locale.sh / README / color_prompt.sh.disabled
                          ← 没有任何东西会执行 /root/autorun.sh
```

后果是最难查的一类失败 —— **静默空跑**：QEMU 正常起、串口正常出 shell、
平台合规 36/36 全过、13 张 screendump 全部保存成功，而 guest 侧**零动作**。
`report/25` 的 600 s 冒烟轮就是这么"全绿但什么都没测到"。

修复：把钩子做成 `t490_round.sh` 的**固定注入步骤**（第 4a 步），并做读回自证：

```text
--- autostart 钩子已注入并回读自证 OK（2519 bytes）---
（源码 scripts/t490/guest-autostart.sh；debugfs write 后 dump 回读 cmp 比对）
```

理由（为什么是 `/etc/profile.d`）：x-kernel 的 PID 1 是 `/bin/sh --login`，
BusyBox ash 的 login shell 会 source `/etc/profile`，而该镜像
`/etc/profile` 结尾正是 `for script in /etc/profile.d/*.sh; do . "$script"; done`
—— 这是跨镜像通用的自动启动挂点，不依赖任何具体发行版的 init。

### 2.2 缺陷 2：Xorg 日志被重定向到不存在的设备

镜像自带 `/usr/local/bin/x11-session` 第 24 行：

```sh
Xorg :0 vt1 -nolisten tcp -auth "$XAUTH" >"$LOG" 2>&1 &      # LOG=/dev/ttyAMA0
```

x-kernel 下 `/dev/ttyAMA0` **不存在**（实测 `/dev/tty0`、`/dev/tty1`、`/dev/ttyAMA0`
全部 MISS，只有 `/dev/console`(5,1) 与 `/dev/tty`(5,0)），shell 在 fork Xorg
**之前**就被重定向挡住 —— 这才是 `report/25` 里那句
`x11-session: line 24: can't create /dev/ttyAMA0: Permission denied` 的真相。

修复：`autorun_x11.sh` 用 `-logfile /root/xorg.log -logverbose 7` 复刻会话结构
（Xorg as root → jwm/chromium 降权到 kiosk + xauth），把日志目标换成 ext4 可写文件。
`-logverbose 7` 是必要的：默认 (II) 级拿不到"设备为什么没被发现"的过程。

### 2.3 缺陷 3：我自己的判据有假成功（M2 原则的直接教训）

第一版门禁写成「`/tmp/.X11-unix/X0` 存在 ⇒ Xorg 起来了」，结果连续两轮打出**假的 `Xorg UP`**：

```text
x11p1：[x11] -> socket /tmp/.X11-unix/X0 出现（1s） → STAGE=x11-xorg-up → "Xorg UP on :0 (pid )"
x11p2：[x11] -> settle 复核通过：进程存活 + socket 仍在 → STAGE=x11-xorg-up → "Xorg UP on :0 (pid )"
```

两个独立缺陷叠加：

1. **socket 会"先建后拆"**。Xorg 在 `CreateWellKnownSockets()` 阶段先建出
   `/tmp/.X11-unix/X0`，之后花约 7 s 加载 glx、再在 DDX/ScreenInit 失败，
   最后才清理 socket。也就是说存在一个 **十几秒的"假可用窗口"**（x11p1 的
   xorg.log 时间轴：8.4 s 建 socket → 15.677 s Fatal），任何固定长度的短窗
   判据都可能正好落在窗口内。x11p2 用 6 次轮询仍然假成功，正是这个原因。
2. **`pgrep -x Xorg` 在本 guest 恒为空**（x-kernel 的 procfs 不暴露进程名），
   所以 `pid` 打不出来；更危险的是变体之间的 `pkill -x Xorg` 也可能匹配不到，
   残留 Xorg 会占住 `/dev/dri/card0` 与 socket，把后续所有变体一起毒化 ——
   而这种污染的表现是"每个变体都失败"，极易被误读成"X11 路线彻底不行"。

最终门禁（v3）改为**功能判据 + 持续窗口 + PID 管理**：

```sh
x_ready() { DISPLAY=:0 XAUTHORITY="$XAUTH" xset q >/dev/null 2>&1; }  # 真能连上才算起来
cleanup_xorg() { kill "$XPID"; ... rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock; }  # 用 PID，不用 pkill
# 门禁：socket 存在 && x_ready，且该状态要**持续** XORG_SETTLE 秒
```

x11p3 上三个变体全部**正确判失败**（`rc=1，从未达到可用状态`），
说明判据这一次是可信的 —— 这是后面敢用它的结果下结论的前提。

---

## 3. 远端链路补齐

官方三页与注入器此前只在本地仓库，T490 上并没有（`~/xk6/scripts/testpage/`
只有旧的 `local-check.html`）。本轮补齐并校验：

| 文件 | 校验 |
|---|---|
| `index.html` | sha256 `831cf28f3748940b…` 本地=远端，CR=0 |
| `interaction.html` | sha256 `58130daa4a2f426f…` 本地=远端，CR=0 |
| `layout.html` | sha256 `a1b04f9aba81b4b7…` 本地=远端，CR=0 |
| `t490_inject_pages.sh` | 远端原本 **MISSING**，已上传 |
| `t490_swap_img.sh` / `t490_inject_pages_dryrun.sh` / `build_xk_t490.sh` | 远端缺失或哈希不一致，已同步 |

注入器干跑台 **19/19 通过**（三页写盘 + 读回逐字节一致 + `/root` 副本 = 入口页 +
无 CR + 入口白名单/路径穿越/缺页/CRLF/读回篡改 五条失败路径全部按预期拒绝）。

> 顺带得到一个流程收益：`t490_round.sh` 在页面集注入失败时**硬失败、不带病起会话**
> （第一次跑就是这个结果：`!! 页面集注入/自证失败，硬失败`，`exit 1`，QEMU 根本没起）。
> 这省下了一轮 12 分钟的无效会话。

---

## 4. 三轮官方页实测

| 轮次 | tag | 时长 | 入口页 | 平台合规 | 截图 | 严格集 | 心跳 | 结论 |
|---|---|---|---|---|---|---|---|---|
| 1 | `x11p1` | 720 s | `index.html` | 36/36 静态 + 15/15 运行 | 13 张 640×480 | 0/13 | 0/12 | 启动链未跑（假成功门禁） |
| 2 | `x11p2` | 420 s | `index.html` | 36/36 静态 + 15/15 运行 | 8 张 640×480 | 0/8 | 0/7 | 同上（settle 窗仍太短） |
| 3 | `x11p3` | 420 s | `index.html` | 36/36 静态 + 15/15 运行 | 8 张 640×480 | 0/8 | 0/7 | **门禁修好，三变体全部正确判失败** |

三轮均为 `PLATFORM_COMPLIANT`；三轮共同点：`screendump` 全部成功、全部 640×480、
逐张哈希相同 → 画面始终是 `Display output is not active.`（virtio-gpu 上从未发生 modeset）。
`x11p3` 额外注入 `drmdumbprobe`，拿到了前两轮拿不到的 errno 级证据。

**跨轮一致性（很强的负面证据）**：三个新轮次的末帧 PPM 与 `report/25` 的 600 s 冒烟轮
**哈希完全相同**：

```text
11b8d01bb05554039a8f9d5b…  x11p1/screenshots/shot-13-final.ppm   （720 s）
11b8d01bb05554039a8f9d5b…  x11p2/screenshots/shot-08-final.ppm   （420 s）
11b8d01bb05554039a8f9d5b…  x11p3/screenshots/shot-08-final.ppm   （420 s）
11b8d01bb05554039a8f9d5b…  （report/25 的 600 s 冒烟轮，历史记录）
```

四轮、跨越多轮参数改动（时长、页面入口、Xorg 变体、探针注入、X 配置），
最后一个像素都没变 —— 说明在 `ScreenInit` 失败的前提下，X 侧的任何参数调整
都不会改变结果，这与 §6 的结论互相印证。

证据目录（各自独立，未覆盖；已回收到本地 `evidence/`）：
`evidence/2026-09-22_t490-x11p{1,2,3}/`，每轮含
`console.log / cmd.txt / env.txt / manifest.txt / timestamps.csv / screenshots/ /
png/ / guest/ / pages.txt / ppm-assert-*.json / ppm-diff-*.json / ppm-summary.txt /
platform-check.txt / platform-compliance.txt`。

---

## 5. 定位链：从"启动链不跑"到"内核 24bpp 缺口"

### 5.1 Xorg 其实已经把 DRM 走通了很远

三轮日志一致（此处取 x11p3）：

```text
(WW) Warning, couldn't open module fbdev          ← 镜像只有 modesetting 一个 DDX
(II) modesetting: Driver for Modesetting Kernel Drivers: kms
(WW) Falling back to old probe method for modesetting
(II) modeset(0): using default device             ← 直接 open /dev/dri/card0，未依赖 sysfs 枚举
(II) modeset(0): Using 24bpp hw front buffer with 32bpp shadow   ★
(==) modeset(0): Depth 24, (==) framebuffer bpp 32
(**) modeset(0): Cannot use glamor with 24bpp packed fb
(II) modeset(0): ShadowFB: preferred YES, enabled FORCE          ★
(II) modeset(0): EDID for output Virtual-1
(II) modeset(0): Modeline "current"x60.0  70.59  1280 1328 1360 1440  800 803 811 817
(II) modeset(0): Output Virtual-1 connected
(II) modeset(0): Up to 1 crtcs needed for screen.
(II) modeset(0): Allocated crtc nr. 0 to this screen.
(EE) AddScreen/ScreenInit failed for driver 0                    ← 死亡点
```

**这是本轮最有价值的进展之一**：x-kernel 的 DRM 已经支持到
`GETRESOURCES`（crtcs=1 / conns=1 / encs=1）、`GETCONNECTOR` + **EDID 读取**、
模式枚举（拿到 1280×800@60）、encoder→crtc 分配，并且 `drmModeCreateDumbBuffer(bpp=32)`
**是通的**。失败发生在拿到前缓冲之后的最后一步。

同时否证了一个曾经的假设：**不是** libdrm 的 sysfs 设备枚举问题。
x-kernel 的 `/sys` 只有 `class` 与 `fs` 两个目录（`/sys/class/drm`、
`/sys/dev/char/226:0/device/drm` 等全部不存在），Xorg 因此打了
`(II) no primary bus or device found`，但 modesetting 走了
`Falling back to old probe method` + `using default device` 直接 open 设备节点，
**绕过了枚举**，所以 sysfs 缺失在这个失败点上不是因。

### 5.2 errno 级证据（`drmdumbprobe`，x11p3 轮）

探针自带编码自证，先确认自己的 `_IOWR` 与内核一致，再测 bpp 矩阵：

```text
  VERSION     = 0x80006400      ← 自证编码
  GETRESOURCES= 0xc04064a0
  CREATE_DUMB = 0xc02064b2
sizeof: version=56 card_res=64 create_dumb=32

open(/dev/dri/card0, O_RDWR) -> 3 errno=0
对照1 VERSION -> rc=0 driver='simpledrm' 1.0.0            ← 编码自证通过
对照2 GETRESOURCES -> rc=0 fbs=0 crtcs=1 conns=1 encs=1   ← modeset 面确实已实现

---- CREATE_DUMB 矩阵（尺寸取 Xorg 实测 Virtual-1 模式 1280x800）----
CREATE_DUMB 32bpp (XRGB8888)       1280x800 bpp=32 -> rc=0  handle=2 pitch=5120 size=4096000
CREATE_DUMB 24bpp (RGB888 前缓冲) 1280x800 bpp=24 -> rc=-1 errno=22 (Invalid argument)   ★
CREATE_DUMB 16bpp (对照)          1280x800 bpp=16 -> rc=-1 errno=22 (Invalid argument)
CREATE_DUMB width=0                0x800 bpp=32  -> rc=-1 errno=22
CREATE_DUMB height=0               1280x0 bpp=32 -> rc=-1 errno=22
```

内核侧对应实现（`io/drmdevice/src/card0.rs:818`，`DrmModeCreateDumb`，CMD `0xB2`）：

```rust
// Only BGRA8888 (32bpp) is supported, so the bpp == 0 / bpp > 64 /
// multiple-of-8 checks are subsumed by the bpp != 32 comparison ...
if c.width == 0 || c.height == 0 || c.bpp != 32 || c.flags != 0 {
    return Err(VfsError::InvalidInput);
}
```

—— 探针测到的 EINVAL 与源码的 `bpp != 32` 判据**逐字对应**，不是巧合。

### 5.3 相关的三处 32bpp-only 约束

| 位置 | 约束 |
|---|---|
| `DrmModeCreateDumb` (0xB2) | `c.bpp != 32 → EINVAL` |
| `DrmModeFbCmd2` (0xB8) | `pixel_format` 仅接受 `XRGB8888 \| ARGB8888` |
| `drivers/contracts/display` | `ScanoutFormat` **只有一个变体** `Bgra8888` |

---

## 6. 用户态出路已穷尽（单变量实验，x11p3）

`autorun_x11.sh` 的变体序列刻意设计成单变量（M3）：

| 变体 | 配置 | 结果 |
|---|---|---|
| V1 | 无配置（基线） | `rc=1`，从未可用 |
| V2 | 显式 xorg.conf（控制组：证明失败不是 `-config` 机制造成的） | `rc=1` |
| V3 | 显式配置 + `ShadowFB=false` + `AccelMethod=none`（关掉 24bpp 前缓冲） | `rc=1` |

V3 是最关键的一次尝试：如果 24bpp 是根因，V3 应该成功。它**没有**，原因是
配置虽然被读到，却被 modesetting 强制覆盖：

```text
[35.000] (++) Using config file: "/root/xorg-noshadow.conf"      ← 配置生效
[35.616] (**) modeset(0): Option "kmsdev" "/dev/dri/card0"
[35.617] (**) modeset(0): Option "ShadowFB" "false"              ← 选项被解析
[35.617] (**) modeset(0): Option "AccelMethod" "none"
[35.618] (**) modeset(0): Cannot use glamor with 24bpp packed fb
[35.619] (II) modeset(0): ShadowFB: preferred YES, enabled FORCE   ← 仍然被强制
[35.615] (II) modeset(0): Using 24bpp hw front buffer with 32bpp shadow
[35.652] (EE) AddScreen/ScreenInit failed for driver 0
```

即：**在 glamor 不可用的前提下，modesetting 会把 ShadowFB 强制打开，
而 ShadowFB 一开，硬件前缓冲就固定为 24bpp packed(RGB888)。**
这一步无法用任何 X 侧配置绕过 ⇒ 修复只能落在内核侧。

（`AccelMethod glamor` 这条路当前也不通：DRM 设备名为 `simpledrm`，
`/dev/dri/` 下只有 `card0`、没有 render 节点，GBM/EGL 起不来；
日志里 `Cannot use glamor with 24bpp packed fb` 也说明 glamor 在这一步已被排除。）

---

## 7. 根因判定与因果强度（诚实标注）

### 7.1 已成立的事实

1. `DRM_IOCTL_MODE_CREATE_DUMB` 在 `bpp=24` 下返回 **EINVAL**（实测，探针自证编码正确）。
2. Xorg 的 modesetting 在本环境下**固定**申请 **24bpp packed** 硬件前缓冲（实测，三轮一致，配置不可覆盖）。
3. Xorg 在申请前缓冲之后的 `ScreenInit` 阶段失败并退出（三轮一致）。
4. 用户态所有可控路径（`ShadowFB`、`AccelMethod`、`kmsdev`、显式配置）均已试尽。

### 7.2 尚未闭环的一点（必须写明，不得当成已证）

Xorg 日志里**没有**一条点名 `CreateDumb`/`drmModeAddFB` 的 `(EE)` 行 ——
`ScreenInit` 返回 FALSE 但未打印驱动级错误。因此
「24bpp 被拒 ⇒ ScreenInit 失败」目前是**强证据支持的因果假设**，
而不是被干预证明的结论（M2：未验证的门禁比没门禁更危险，同理未闭环的因果链
不能写进结论）。

**闭环手段（下一步，成本低）**：在内核里让 `DrmModeCreateDumb` 接受 `bpp=24`
（暂时按 32bpp 步长分配并返回 `pitch=w*4`，只为证明因果，不求画面正确），
重跑短轮：

- 若 Xorg 越过 `ScreenInit` 并出现真实 modeset（`screendump` 尺寸变化 / 心跳出现）
  ⇒ 因果链**由干预证明**，随后再做正规的 24bpp 支持；
- 若仍失败 ⇒ 说明还有第二个缺口（届时按新的 `xorg.log` 继续推进），
  本次假设作废并立碑，避免后人重复投入。

---

## 8. 下一步（按优先级）

1. **干预性验证**（见 §7.2）：内核 `DrmModeCreateDumb` 接受 24bpp → 短轮复测。
   这是一次单变量内核改动 + `git tag` 基线，符合 R-1 与"before/after 必须有 tag"。
2. **若因果成立，做正规修复**。需要明确一个**未知点**：virtio-gpu 的 2D 扫描输出
   是否支持 24bpp packed 格式（`VIRTIO_GPU_FORMAT_{B8G8R8,R8G8B8}_UNORM` / QEMU 侧
   pixman 映射）。若不支持，则"支持 24bpp"这条路走不通，应改为让
   **DXE 侧不进入 24bpp 路径**（例如让内核把 DRM 版本/能力暴露成 modesetting
   会选 32bpp 的形态），这需要先读清 modesetting 选择 `fb_format` 的确切代码路径
   （镜像内没有源码，需按 xorg-server 1.21.1 对应版本核对）。
3. **G6（鼠标 evdev）优先级维持高位**：官方 `interaction.html` 的 A 段要真实点击、
   B 段要键入 + 点击 + 链接跳转；当前 guest `/dev/input` 只有 `event0` + `mice`，
   鼠标设备节点缺失会直接影响决赛的 JS 交互页测试。
4. `/dev/shm` 的 0 容量问题（下一节）需单独修，它在 chromium 起来之后才会变成主因。
5. 证据目录清洁：`evidence/2026-09-22_t490-agentos-x11/` 有多一层同名嵌套（历史遗留）。

### 8.1 本轮新增的一处待修（未影响本轮结论）

`/dev/shm` 在本 guest 里是**0 容量**的挂载点：

```text
[x11] /dev/shm remount size=512m 成功
[x11] dev/shm: none 0 0 0 0% /dev/shm      ← remount 报成功，但容量仍为 0
```

`mount -o remount,size=` 在这里静默无效（返回 0 但未生效）。
这不影响本轮结论（Xorg 早于 chromium 就失败了），但 Xorg 一旦通了，
chromium 会在渲染器启动时撞上它。修法倾向于 `umount` 后重新 `mount -t tmpfs`，
或直接给 chromium 挂 `--disable-dev-shm-usage` 并把 `TMPDIR` 指到 ext4 上的目录。

---

## 9. 本轮产物

新增：

| 文件 | 作用 |
|---|---|
| `scripts/t490/guest-autostart.sh` | autostart 钩子源码（注入为 `/etc/profile.d/99-autostart.sh`） |
| `scripts/t490/autorun_x11.sh` | guest 侧 X11 kiosk 启动器（功能门禁 + 单变量变体 + 诊断） |
| `scripts/t490/drmdumbprobe.c` | `CREATE_DUMB` 的 bpp 接受度探针（自带编码自证） |
| `report/27`（本文） | 定位链与证据归档 |

修改：

| 文件 | 变更 |
|---|---|
| `scripts/t490/t490_round.sh` | 新增第 4a 步：autostart 钩子注入 + 读回自证（`INJECT_AUTOSTART=0` 可关）；钩子纳入注入结果校验 |
| `scripts/t490/round_assert.sh` | 回收 X11 系 guest 日志（`autorun-x11.log`/`xorg.log`/`xorg-stderr.log`/`jwm.log`）+ 新增 §⑧「X11 启动链判定摘录」 |
| `scripts/t490/pull_guest_logs.sh`（调用侧） | X11 日志以「额外文件」传入，避免 dump 出 0 字节被误判成"无日志" |

T490 侧同步：上述脚本 + `t490_inject_pages.sh` / `t490_swap_img.sh` /
`t490_inject_pages_dryrun.sh` / `build_xk_t490.sh` + 官方三页与参考图。

---

## 10. 合规声明

- **R-1（优化须以内核为出发点）**：本轮的用户态改动（`autorun_x11.sh`、xorg.conf）
  是**启停、诊断与兼容**用途，**不写入任何优化收益表**。真正的修复方向已收敛到内核
  （`io/drmdevice` 的 24bpp 约束），下一步就是内核补丁。
- **R-2（评分数据须来自纯 TCG）**：三轮全部 `2g / 4 vCPU / -cpu cortex-a76 /
  命令行无任何 -accel`，平台预检 15/15、静态预检 36/36；完整 QEMU 命令行随证据归档。
- **S-2 / S-3**：`--no-sandbox`、`--disable-dev-shm-usage` 等属起步简化，
  已在 `autorun_x11.log` 与本文 §6 如实标注；本轮未使用伪造 sysfs
  （`/sys` 全部只读探测，日志里明确写「不写伪 sysfs」）。
- **证据纪律**：三轮各自新建目录，未覆盖任何既有 run；`report/25` 的结论
  在本轮被**修订**（其"先修启动链"已完成，而阻塞点前移到内核 DRM 层），
  未改动其原文。
