# 32 · 勘误：GETPLANE「48 字节」结论错误 —— 缺口 D 撤销

> 日期：2026-09-22 夜 ｜ 性质：**勘误（本文推翻 [report/31](31-缺口D-GetPlane结构体缺字段.md) 的核心事实）**
> 关联：[report/31](31-缺口D-GetPlane结构体缺字段.md)（被本文推翻）、
> [report/29](29-缺口A修复闭环-DRM属性面编号对齐uapi.md)（缺口 A 仍有效，保留）、
> 证据：`evidence/2026-09-22_t490-stage0-freeze/`、`scripts/t490/abi_probe.c`
>
> **一句话**：`struct drm_mode_get_plane` 的标准 uapi 是 **6×u32 + 1×u64 = 32 字节，
> 没有 `crtc_x/crtc_y/x/y`**（那四个字段属于 `drm_mode_set_plane`，不是 GETPLANE）。
> report/31 引用的「mainline 48 字节」定义是对 uapi 的**误读**；据此执行的 `p3_apply.sh`
> 把**本来正确的内核改成了错误的**，并使标准 libdrm 客户端（`drmModeGetPlane`）失效。

---

## 1. 事实基线（机器输出，可复现）

`scripts/t490/abi_probe.c` —— 宿主 x86_64 编译运行 + aarch64 musl 交叉编译双重验证：

```text
== A. 标准头文件事实 ==
sizeof(drm_mode_get_plane) = 32
offsets: plane_id=0 crtc_id=4 fb_id=8 possible_crtcs=12 gamma_size=16 count_format_types=20 format_type_ptr=24
DRM_IOCTL_MODE_GETPLANE    = 0xC02064B6  (_IOC_DIR=3 TYPE=0x64 NR=0xB6 SIZE=32)

== B. 用 x-kernel 公式复算 ==
x-kernel iowr(标准 32B)    = 0xC02064B6
x-kernel iowr(HEAD 7 字段) = 0xC02064B6   ← 与标准一致 ✓（HEAD 内核本可命中 libdrm 请求）
x-kernel iowr(10 字段 48B) = 0xC03064B6   ← 不一致 ✗（当前内核即此形态 ⇒ libdrm 请求落空）
```

- aarch64 交叉工具链（musl-cross）同源编译**通过**，含 4 条编译期断言：
  `get_plane==32 / plane_res==16 / obj_get_properties==32 / get_property==64`
- 头文件指纹：
  宿主 `/usr/include/drm/drm_mode.h` = `651a780c0494bd73f1ee4176e8ae29336a604614f9b036ef938761e9e5ffde95`
  aarch64 工具链 `…/include/drm/drm_mode.h` = `4464ce6c971b8753963778f3e3f911c59dcc8e75e67e526f5094c2f8392e2200`
- 标准头文件中 `struct drm_mode_get_plane` 的字段序列（原文摘录，见 `abi-baseline.txt`）：
  `plane_id, crtc_id, fb_id, possible_crtcs, gamma_size, count_format_types, __u64 format_type_ptr`

## 2. 机制复原：一个「自洽的错」如何变成内核回归

1. `io/drmdevice/src/consts.rs:17` 的 `iowr::<T>()` 把 `size_of::<T>()` 编进请求值第 16–29 位
   （与 Linux `_IOWR` 同构，已逐字核对：`(dir<<30)|(size<<16)|(ty<<8)|nr`）；
2. `card0.rs` 的分派是 `match cmd { <T as DrmIoctl>::CMD => … }` —— **精确匹配整个 u32**；
3. 探针按误读的「48 字节 uapi」编写 ⇒ 对当时**正确**的 32 字节内核发出 `size=48` 请求
   ⇒ `errno=95`（EOPNOTSUPP，未命中任何分支）；
4. 这次失败与作者的理论预期**恰好一致** ⇒ 确认偏误：被解读为「内核缺字段」，
   而不是「探针写错」；且探针当时**没有**标准尺寸自检，无法自证；
5. `p3_apply.sh` 把内核改成 48 字节 ⇒ 探针变绿（探针 ↔ 内核自洽），
   但**标准 libdrm 的 32 字节请求从此刻起必然落空**。

**教训（已固化为纪律）**

- 探针必须锚定**标准头文件**，不得锚定内核实现；
- 「探针通过」只有在探针自身通过 `[PROBE_ABI]` 标准尺寸自检时才算证据
  —— 已写入 `drmplaneprobe.c`（含 4 条 `_Static_assert` + 运行期自检 + `[PROBE_EXIT]` 机器行）；
- 任何 ABI「修复」必须先取得**标准客户端**（真实 libdrm）的 before 证据。

## 3. 影响面（谁被污染了）

| 项 | 状态 |
|---|---|
| 内核工作树（未提交） | `io/drmdevice/src/drm.rs` +16/−2、`card0.rs` —— 错误扩展 |
| kernel.bin | `2105fc43…` → **`6ab03917…`**（当前所有会话用的都是它） |
| 标准 libdrm `drmModeGetPlane` | 失效（请求值 0xC02064B6 无对应分支） |
| report/31 §5 的 before/after 表 | **两侧都建立在错误布局上**，不构成有效闭环 |
| 证据轮次 | weston7（21:21）、weston8（21:29）用的是 `6ab03917` |
| report/31 §4 的「修复」 | 应回退（保留缺口 A 的编号修复） |

## 4. 一个必须纠正的推论（重要）

**weston6（20:56）的日志里同样出现**：

```text
[12:48:44.872] Failed to find primary plane for output Virtual-1
```

而 weston6 早于内核构建时间 21:03 ⇒ 它跑的是 **p3 之前的正确内核**（见 §5 的归因方法）。

⇒ **48 字节回归不是 Weston 失败的原因**。Weston 的 `Failed to find primary plane`
在正确 ABI 下就已存在，另有原因。
⇒ 回退该回归是**必要的**（它独立地破坏标准客户端，是确凿的真缺陷），
但**不足以**打通 Weston。后续定位必须回到 Weston 自身的平面枚举路径。

## 5. 归因方法（本次补齐的取证缺口）

历史上**所有证据目录都没有记录内核哈希** ⇒「某一轮到底跑的是哪个内核」只能靠文件
时间戳间接推断（本次即如此）。已修复：`t490_round.sh` 现在会在每轮结束时把
`build-manifest.txt`（内核 / 基础镜像 / 页面集 / autorun / 关键脚本的 sha256 + git HEAD）
写进该轮证据目录。归因时间线：

| 时刻 | 事件 | 内核 |
|---|---|---|
| 20:56 | weston6 会话（同样报 primary plane 失败） | p3 之前（正确 32B） |
| 21:01 | planeprobe 会话（探针 48B 对内核 32B ⇒ errno 95） | p3 之前（正确 32B） |
| 21:03 | **p3 应用后构建** | 6ab03917（48B，回归） |
| 21:21 / 21:29 | weston7 / weston8 会话（症状不变） | 6ab03917 |

## 6. 回退执行与 before/after 闭环（阶段 1.3 / 1.4 —— **已完成**）

**回退脚本**：`scripts/t490/p3_revert.sh`（幂等 + 形态断言；**不动**缺口 A 的编号修复）。
执行后断言：字段序列回到标准 7 字段 ✓；`GETPROPERTY=0xA8` / `GETPROPBLOB=0xAA` 仍在 ✓；
`card0.rs` 无 `p.crtc_x` 残留 ✓。内核 `6ab03917…` → **`a01bf2e6…`**。

**三条独立证据链**（同一探针、同一镜像 `bb25e0b2…`、只换内核）：

| 判据 | before（`6ab03917…`，48B） | after（`a01bf2e6…`，32B） |
|---|---|---|
| 手写标准探针 `drmplaneprobe` | `GETPLANE rc=-1 errno=95` → `verdict=GETPLANE_FAIL`（exit 3） | **`rc=0 errno=0 crtc_id=16 possible_crtcs=0x1 count_formats=2`** → `verdict=PLANE_OK`（exit 0） |
| **标准 libdrm 客户端** `drmstdprobe` | `drmModeGetPlane(plane_id=64) FAILED errno=95` → `STD_FAIL` | **`drmModeGetPlane(plane_id=64) OK`**（formats `0x34325258` / `0x34325241` = XRGB8888 / ARGB8888）→ `STD_OK` |
| **ioctl 观测器** `iocspy`（libdrm 实际请求值） | `req=0xc02064b6 size=32 nr=0xb6 → rc=-1 errno=95` | **`req=0xc02064b6 size=32 nr=0xb6 → rc=0`** |
| 探针必验项（`GATE` 行） | `probe_fail=3` | **`probe_fail=0`** |

**证据目录**：`evidence/2026-09-22_t490-std1`（before）、`evidence/2026-09-22_t490-std2`（after）；
两者的 `build-manifest.txt` 分别记录了所用内核哈希（该文件是阶段 0 新增的取证项，
恰好在本轮发挥了作用 —— 历史证据完全没有这个信息，见 §5）。

> **判读**：`iocspy` 那一行是决定性的：它直接看到 libdrm 发出的请求值就是
> `0xc02064b6`（32 字节），而 48 字节内核只认 `0xc03064b6` ⇒ `errno=95`。
> 这不再是"从源码推断"，而是**运行期事实**。

**仍未解决（重要）**：Weston 的 `Failed to find primary plane` **不是**这个回归造成的
（weston6 在正确 ABI 上同样失败，见 §5）。回退只是修复了一个独立的真缺陷；
Weston 的根因继续按阶段 3 的调试顺序定位（真实 GETPLANE → 属性元数据 → 格式与 CRTC 匹配）。

## 7. 合规声明

- 全部结论来自 T490 的只读核查与**双编译器**编译验证，未混入 KVM/HVF 任何数据；
- 本轮未修改内核、镜像与任何历史证据（工作树保持原样，差异已完整存档于
  `evidence/2026-09-22_t490-stage0-freeze/source-state.txt`）；
- 本勘误保留 report/31 原文并可回溯（其顶部已加勘误横幅），不删除、不改写历史结论。
