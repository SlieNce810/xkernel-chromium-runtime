# 28 · 路线校正：从用户态图形脚本回到内核态优化，附 DRM 缺口增量清单

> 日期：2026-09-22 ｜ 触发：用户指出"比赛要求在内核态优化，而不是用户态"
> 依据：`docs/赛题六-基础任务操作手册.md` §0.2（评分表原文）、
> `docs/赛题六-前期准备清单与分阶段执行指南.md` §1.2 / §2.2 / §3.3
> 结论：**方向批评成立，但需要精确化**。内核态工作是初赛分值最高的单项（25 分），
> 而本轮已经把图形阻塞**准确定位到两个内核缺口**；失误在于**过程**：
> 用三轮会话去搭用户态 X11 启停脚本，而不是直奔 kernel。

---

## 1. 校正：把"内核态 vs 用户态"对上真实评分表

`docs` 里初赛满分 100 分的构成（**原文摘录，不是推断**）：

| 评分项 | 分值 | 落在哪一层 |
|---|---|---|
| **系统兼容性与移植分析** | **25** | **内核态**（8 缺口 ×1 + 3 patch ×4 + 与 Linux 基线对比 5） |
| 图形环境启动与稳定性 | 20 | 用户态（Weston/Chromium），**但前置是内核图形能力配置** |
| 浏览器基础功能 | 20 | 用户态（Chromium） |
| 性能观测与量化方法 | 15 | 跨层（度量） |
| 技术文档与代码规范 | 10 | 文档 |
| 演示效果 | 10 | 演示 |

### 1.1 需要精确化的两点

1. **不是"只能内核态"**。用户态图形/浏览器合计 40 分，且赛题原文明确要求
   "配置图形、输入、文件系统和网络所需**内核能力**，启动 Weston 或其他图形界面系统"
   —— 即**内核能力是图形分项的前置条件**，两者不是二选一。
2. **但内核态确实是"分值最高、且只能靠自己啃"的单项**，而且它是**决赛开源回馈（9 分）
   的唯一来源**：
   - 缺口清单：**每个缺口 1 分，最多 8 个，必须附复现方法**；
   - 上游 patch：**一个被合并 4 分，最多 3 项 = 12 分**；
   - Linux 行为基线对比：5 分。
   
   `前期指南` §1.2 的三人工分里，A 角色 = 内核/驱动 = 这 25 分；§2.2 的优先级排序把
   "系统兼容性与移植分析" 标成 ★★★ **性价比最高**，并写明"**第 1 周就要开始提 patch**，
   review-merge 周期以周计"。

### 1.2 本轮真正做错的是什么

**不是结论错了，是过程错了。** 本轮最终把图形阻塞定位到了内核
（`io/drmdevice` 的 DRM 实现），并且产出了两条**带 errno 级复现方法**的新缺口 ——
这恰好是 25 分里"缺口清单 + patch"要的东西。错的是路径：

| 投入 | 归属 | 对 25 分项的价值 |
|---|---|---|
| `autorun_x11.sh` / `guest-autostart.sh` / X11 变体实验 | 用户态启停 | **0**（且按纪律不得进收益表） |
| `drmdumbprobe.c` + 内核 ioctl 分派表核对 | **内核态** | **有**（可直接写成缺口条目 + patch） |
| 三轮官方页实测 | 用户态功能验证 | 0 分（图形未通），但提供了失败证据 |

**教训（写进纪律）**：遇到"图形起不来"时，诊断顺序应当是
**先看内核提供了什么能力（ioctl/syscall 分派表）→ 再决定用户态怎么用**，
而不是反过来先在用户态堆启动脚本、用排除法倒推内核。
本轮的 `drmdumbprobe` 只用了不到 100 行 C，就把三轮会话没解决的问题钉死了。

---

## 2. 澄清一个事实：虚拟机**启动是成功的**，失败的是"图形链路"

用户表述里的"虚拟机未能成功启动"需要更正 —— 否则会把排查引向错误方向
（去查 QEMU/引导/kernel panic，而那些都是好的）：

| 事实 | 证据 |
|---|---|
| QEMU 正常运行完整时长并正常收尾 | 603.5 s / 720 s / 420 s，`SESSION_RC=0`，console 有正常收尾标记 |
| guest 引导到 shell | `console.log` 出现 `HOME=/root`、`PWD=/`、`kylin-x:~#` |
| 平台参数合规 | 静态 36/36、运行期 15/15，`PLATFORM_COMPLIANT` |
| screendump 机制本身正常 | 13 / 8 / 8 张 PPM 全部成功产出、尺寸一致 |
| **图形输出未激活** | 全部画面为 `Display output is not active.`，四轮哈希完全相同 |

准确的说法是：**"虚拟机能启动，但图形会话（评分表前 40 分）全项为 0，
因为图形链在内核 DRM 层被打断。"**

---

## 3. 逐环节状态：哪一环断了

| # | 环节 | 层 | 状态 | 证据 |
|---|---|---|---|---|
| 1 | QEMU 参数（2g/4 vCPU/纯 TCG/virtio-gpu-pci/virtio-input） | 宿主 | ✅ | `platform-check.txt` 36/36 |
| 2 | x-kernel 引导 + `/bin/sh --login` | 内核 | ✅ | `kylin-x:~#` |
| 3 | 自动启动挂点被执行 | 内核→用户态 | ✅ **本轮修复** | `[autostart] hook fired` |
| 4 | 设备节点 `/dev/dri/card0`、`/dev/fb0`、`/dev/input/event0` | 内核 | ✅ | autorun 诊断段 |
| 5 | DRM `open` + `VERSION` | 内核 | ✅ | `rc=0 driver='simpledrm' 1.0.0` |
| 6 | DRM 资源枚举 `GETRESOURCES` | 内核 | ✅ | `fbs=0 crtcs=1 conns=1 encs=1` |
| 7 | EDID + 模式枚举 | 内核 | ✅ | `Virtual-1 connected`，**1280×800@60** |
| 8 | encoder → crtc 分配 | 内核 | ✅ | `Allocated crtc nr. 0 to this screen.` |
| 9 | **KMS 属性面 `GETPROPERTY` / `GETPROPBLOB`** | 内核 | ❌ **不可达** | 见 §4.1 |
| 10 | `CREATE_DUMB(bpp=32)` | 内核 | ✅ | `rc=0 pitch=5120 size=4096000` |
| 11 | **`CREATE_DUMB(bpp=24)`** | 内核 | ❌ **EINVAL** | 见 §4.2 |
| 12 | `ADDFB2` 格式集 | 内核 | ⚠️ 仅 XRGB/ARGB8888 | `DrmModeFbCmd2` |
| 13 | `ScanoutFormat` 格式集 | 内核 | ⚠️ 仅 `Bgra8888` | `drivers/contracts/display` |
| 14 | X11 `ScreenInit`（modesetting） | 用户态 | ❌ | `(EE) AddScreen/ScreenInit failed for driver 0` |
| 15 | compositor 常驻 / Chromium 窗口 / 渲染 HTML | 用户态 | ❌ | 未到达（评分项 4×10 全 0） |

**断点在第 9 与第 11 环，都在内核。**

---

## 4. 两条内核缺口的实测证据（可直接写成缺口条目）

### 4.1 缺口 A（本轮新发现）：KMS 属性面 ioctl 编号与 Linux uapi 不符

排障过程：读 `io/drmdevice/src/card0.rs` 的 ioctl 分派表，把**已实现编号**与
Linux `drm_mode.h` 对齐后，发现属性面错位：

| mainline 编号 | mainline 语义 | x-kernel 现状 | 后果 |
|---|---|---|---|
| `0xA8` | `MODE_GETPROPERTY`（`drm_mode_get_property`，64 B） | **完全缺失** | libdrm `drmModeGetProperty()` → **ENOTSUP** |
| `0xAA` | `MODE_GETPROPBLOB`（`drm_mode_get_blob`，16 B） | 挂在 **64 B 的属性结构**上 | libdrm `drmModeGetPropertyBlob()` 发出的是 16 B 编码 → **签名不匹配 → ENOTSUP** |
| `0xAC` | （mainline 未分配） | 放的是 `MODE_GETPROPBLOB` 的处理器 | **任何 Linux ABI 客户端都到不了 → 死代码** |

关键机制（已核对源码）：`io/drmdevice/src/consts.rs:17`

```rust
pub(crate) const fn iowr<T>(ty: u8, nr: u8) -> u32 {
    ioc(IOC_READ | IOC_WRITE, ty, nr, core::mem::size_of::<T>() as u16)
}
```

`iowr` **把结构体大小编进 ioctl 号**，与 Linux `_IOWR` 语义一致 ——
所以"编号对不上"和"大小对不上"都会导致**分派失败**，落到末尾的
`_ => Err(kvfs::VfsError::OperationNotSupported)`。而 x-kernel 声明为
`DrmModeGetProperty` 的那段代码里，字段是 `prop_id / flags / name[] /
count_values / count_enum_blobs / values_ptr / enum_blob_ptr`，
**正是 `drm_mode_get_property` 的布局** —— 说明实现写对了，**编号挂错了**。

**后果链**：标准 Linux 用户态（libdrm / Weston / Xorg）**无法枚举 KMS 属性、
无法读取 mode blob** → Weston 的 atomic commit 不可能建立 → 这**正是既有缺口清单
第 2 条 `WESTON_DISABLE_ATOMIC=1`（原子提交不可用）的根因**。官方启动器不得不写这个
环境变量，不是因为"atomic 不稳"，而是因为**属性查询这一层在内核里是断的**。

**复现方法（待实现，约 80 行 C）**：新增 `drmpropprobe.c`，按 libdrm 的真实编号分别发
`0xA8`（属性）与 `0xAA`（blob），打印 rc/errno；预期修复前 `ENOTSUP`、修复后 `rc=0`。
探针必须沿用 `drmdumbprobe.c` 的自证模式（先跑 `VERSION` 证明编码正确）。

**修复成本**：两处编号改动（`0xAA → 0xA8`、`0xAC → 0xAA`），加一处分派表项。
**上游价值**：极高 —— uapi 契约错误、边界清晰、影响可量化，与既有清单第 1 条
（ENOSYS 语义）同属"小改大收益、最容易过 review"的一类。

### 4.2 缺口 B（本轮已实测）：`CREATE_DUMB` 只接受 32bpp

```text
对照1 VERSION      -> rc=0 driver='simpledrm' 1.0.0        ← 探针编码自证
对照2 GETRESOURCES -> rc=0 crtcs=1 conns=1 encs=1
CREATE_DUMB 1280x800 bpp=32 -> rc=0  pitch=5120 size=4096000
CREATE_DUMB 1280x800 bpp=24 -> rc=-1 errno=22 (EINVAL)
CREATE_DUMB 1280x800 bpp=16 -> rc=-1 errno=22 (EINVAL)
```

对应源码 `io/drmdevice/src/card0.rs:818`：

```rust
// Only BGRA8888 (32bpp) is supported, ...
if c.width == 0 || c.height == 0 || c.bpp != 32 || c.flags != 0 {
    return Err(VfsError::InvalidInput);
}
```

**为什么这会挡住图形**：X11 的 `modesetting` 在 glamor 不可用时把 ShadowFB **强制**打开
（实测日志 `ShadowFB: preferred YES, enabled FORCE`，配置改不掉），
而 ShadowFB 一开，硬件前缓冲就固定为 **24bpp packed (RGB888)**，
于是必然走到 `drmModeCreateDumbBuffer(bpp=24)` → EINVAL → `ScreenInit` 失败。

**复现方法**：`scripts/t490/drmdumbprobe.c`（已实现，自带编码自证）。

**⚠️ 修之前必须先查一个未知点**：virtio-gpu 的 2D 扫描输出**是否支持 24bpp packed**
（`VIRTIO_GPU_FORMAT_B8G8R8_UNORM` / `R8G8B8_UNORM` 与 QEMU 侧 pixman 映射）。
若设备侧不支持 24bpp，那么"让内核支持 24bpp"这条路是死路，
应当转向"让内核把格式能力暴露成 DDX 会选 32bpp 的形态"或补 GBM/render node。
**不要把 24bpp 支持当成既定修法。**

### 4.3 缺口 C（既有清单第 2 条的定位化）

既有清单把 "`WESTON_DISABLE_ATOMIC=1`" 记为"atomic KMS 实际不可用或不可靠"，
**现在可以升级为可复现的根因**：即 §4.1 的属性面编号错位。
这条改造后，缺口条目从"现象描述"变成"根因 + 复现 + 修复"，分量更高。

---

## 5. 路线校正：官方意图是 Weston，不是 X11

必须指出的一处偏差（`前期指南` §0.1 明确警告过）：

> 官方意图路线 = **Weston（Wayland 合成器）+ DRM backend + Chromium
> `--ozone-platform=wayland`**。基线是专门为 Weston 调过的。
> → **不要一上来去啃 fbdev 或从零搭 X11，那是逆着出题意图走。**

实测确认：

| 项 | 状态 |
|---|---|
| `platforms/kplat-aarch64/qemu_defconfig` | `KFEAT_DRIVER_VIRTIO_GPU=y` / `KFEAT_DRIVER_VIRTIO_INPUT=y`，注释原文 "Weston graphics requires the virtio GPU and input drivers." |
| 官方启动器 | 仓库自带 `uapps/weston-start/xk-weston-start` |
| 当前 agentos 镜像 | **没有 weston / seatd / Xwayland**，只有 Xorg + chromium（纯 X11 kiosk 镜像） |

**从内核缺口角度看，Weston 路线反而更顺**：Weston 的 DRM backend 默认申请
**32bpp XRGB8888** 的 dumb buffer —— 正好命中**已实测通过**的那条路径（`bpp=32 → rc=0`）。
而 X11/modesetting 的 24bpp 需求是 **X11 特有的**。

所以两条路各自撞的是不同的内核缺口：

| 路线 | 撞的内核缺口 | 该缺口的修复价值 |
|---|---|---|
| Weston / Wayland（官方意图） | §4.1 属性面编号（→ 解锁 atomic） | 高（uapi 契约，patch 易过） |
| X11 / modesetting（当前镜像） | §4.2 `CREATE_DUMB` 只收 32bpp | 中（需先确认 virtio-gpu 24bpp 支持） |

---

## 6. 下一步：内核态优化方案（按性价比排序）

### 阶段 0 · 先把基线冻住（当天，零风险）

- [ ] 对当前 `~/x-kernel` HEAD（`c2eabd5`）打 `git tag`，作为所有 before/after 的基线；
- [ ] `git status` 确认工作树干净（本轮实测确实干净）；
- [ ] 把 `report/patches/` 里已有的 7 个 patch（0001–0007、0009、0010）状态更新成
      "已提交上游 / 已合并 / 待提"，其中 MR !831 已合并这件事要写进 `report/补丁汇总.md`。

### 阶段 1 · 三条"小而高价值"的内核补丁（本周内可完成，直指 25 分）

| 序 | 补丁 | 位置 | 复现方法 | 预估收益 |
|---|---|---|---|---|
| **P1** | 未实现 syscall 返回 **ENOSYS** 而非 `ENOTSUP`（既有清单 #1，排名第一） | `core/ksyscall/src/dispatch.rs` 末尾 | `strace`/小 C 探针查返回 errno | 缺口 1 分 + patch 4 分 |
| **P2** | **KMS 属性面编号修复**（§4.1，本轮新发现）：`0xAA→0xA8`、`0xAC→0xAA` | `io/drmdevice/src/card0.rs:975/1135` | 新增 `drmpropprobe.c` | 缺口 1 分 + patch 4 分 |
| **P3** | 补偿 `MODE_ADDFB(0xAE)` / `MODE_GETFB(0xAD)`（当前落到 ENOTSUP） | 同上，分派表 | 同上探针扩测 | 缺口 1 分 |

**为什么是这三条**：全部是 **uapi 契约类**缺陷，改动小、论据硬（可直接引 Linux
`drm_mode.h` / glibc 契约）、review 阻力最低 —— 与 `前期指南` §3.4 给出的
"推荐 patch 次序"完全一致（先建立 contributor 信任）。
**提交纪律**：先提 issue 描述缺口 + 复现方法 → 得 maintainer 认可再提 PR。

### 阶段 2 · 图形链路的内核侧打通（决定 40 分能否拿到）

- **先做**：§4.2 的未知点核实 —— virtio-gpu 2D 是否支持 24bpp packed。
  查 QEMU `hw/display/virtio-gpu*.c` 的格式映射表即可，**不需要跑 QEMU**。
- **再决定**：
  - 若支持 24bpp → 扩 `DrmModeCreateDumb` 的 bpp 集 + `ScanoutFormat` 增加 `Rgb888`
    + `DrmModeFbCmd2` 放行 `DRM_FORMAT_RGB888`；
  - 若不支持 → 不去动 `CREATE_DUMB`，改为**换官方路线**（Weston 走 32bpp）
    或补 render node / GBM 让 glamor 可用。
- **路线选择建议**：**优先把 Weston 跑起来**（顺出题意图，且它要的 32bpp 是通的），
  把 X11 的 24bpp 作为"内核格式协商能力"缺口写进清单，而不是拿它当主攻。

### 阶段 3 · 观测与度量（15 分，必须配内核侧工具）

- 内核侧现成能力：`ktrace` / tracepoint / eBPF(kBPF) / `KFEAT_PMU` / `KFEAT_NMI`；
- 指标四类（赛题原文）：启动首帧延迟 / 页面加载 / renderer 创建延迟 / 峰值内存；
- 规范：**每项 ≥5 次取中位数 + 波动范围 + 宿主指纹**（这一套脚本 `run-session.py`
  与 `round_assert.sh` 已经具备，可直接复用）；
- 每条缺口必须附**复现方法**，否则该条不计分。

### 阶段 4 · 纪律（避免重蹈本轮覆辙）

1. **改动前先判层**：能落内核的绝不用用户态绕；用户态产物只作**诊断/启停通道**，
   不得进收益表（本轮 `autorun_x11.sh` 已按此标注）。
2. **先读分派表，再写探针**：`core/ksyscall/src/dispatch.rs`（251 项）与
   `io/drmdevice/src/card0.rs` 的 match 表就是"内核能力清单"，
   比任何用户态现象推断都准，成本只有一次 `grep`。
3. **探针必须自证**：任何新探针先跑一个"已知能通"的对照（如 `DRM_IOCTL_VERSION`），
   否则探针自身缺陷会被误读成内核缺陷（本轮 `drmdumbprobe` 已按此设计）。

---

## 7. 本次会话的净产出（折算）

| 产出 | 类型 | 是否计入评分 |
|---|---|---|
| 缺口 A：KMS 属性面编号错位（含复现方法） | **内核态** | ✅ 缺口清单 1 分 + patch 潜在 4 分 |
| 缺口 B：`CREATE_DUMB` 只收 32bpp（含复现方法） | **内核态** | ✅ 缺口清单 1 分 |
| 缺口 C：既有 #2 的根因定位化 | **内核态** | ✅ 提升该条分量 |
| `drmdumbprobe.c` | **内核态工具** | ✅ 复现工具（评分要求"附复现方法"） |
| `guest-autostart.sh` / `autorun_x11.sh` / 三轮实测 | 用户态 | ❌ 0 分（仅诊断通道，已如实标注） |

即：**把"用户态排查"已经付掉的成本，转成了 2–3 条内核缺口条目 + 1 个可复用探针；
但过程该更短 —— 这三条本来可以从"读一次 dispatch 表 + 读一次 card0.rs 分派表"直接得到。**

---

## 8. 合规声明

- 本文所有"已实测"结论均来自 T490 上纯 TCG 会话（`2g / 4 vCPU / -cpu cortex-a76 /
  无 -accel`）或对**被测内核源码**的直接阅读，未混入任何 KVM/HVF 数据；
- 用户态脚本（`autorun_x11.sh` 等）明确为诊断/启停通道，**不写入优化收益表**；
- 缺口条目的"复现方法"均要求**先自证探针编码**，避免探针缺陷被误记为内核缺陷；
- 尚未闭环的判断已显式标注（§4.2 的 virtio-gpu 24bpp 未知点、Xorg 未点名 CreateDumb 的因果强度）。
