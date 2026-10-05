# 31 · 缺口 D：`drm_mode_get_plane` 结构体缺字段（uapi 契约错位·第二例）

> ## ⛔ 勘误（2026-09-22 夜）：本文核心事实错误，结论已撤销
>
> 经与标准 uapi 头文件（宿主 `/usr/include/drm/drm_mode.h`）及 aarch64 musl 工具链
> 同名头文件**双向核对**：`struct drm_mode_get_plane` 是
> **6×u32 + 1×u64 = 32 字节，没有 `crtc_x/crtc_y/x/y`** —— §2 引用的「mainline 48 字节」
> 定义是误读（那四个字段属于 `drm_mode_set_plane`，GETPLANE 里从来没有它们）。
>
> 因此本文：§4 的「修复」实为**回归**（把正确的 32B 改成 48B，破坏了标准 libdrm 客户端）；
> §5 的 before/after 两侧都建立在错误布局上，**不构成有效闭环**；
> §1 的 `errno=95` 是**探针自身 48B vs 内核 32B** 失配所致，不是内核缺陷；
> §6 的「系统性核对」方向仍成立。
>
> 完整勘误、机器证据与回退方案见 **[report/32](32-勘误-GETPLANE-48字节结论错误与缺口D撤销.md)**。
> **阅读本文前请先读 report/32。**

> 日期：2026-09-22 晚 ｜ 发现环节：Weston M2 攻坚（weston6 → planeprobe 轮）
> **一句话**：内核 `DrmModeGetPlane` 少了 mainline uapi 的 `crtc_x/crtc_y/x/y` 四个 u32
> ⇒ `sizeof` 32 而非 48 ⇒ `iowr<T>()` 把 size 编进 ioctl 号 ⇒ 与 libdrm 发出的编码不等
> ⇒ `GETPLANE` 落入分派表默认分支 ⇒ **Weston 的 plane 枚举逐个失败** ⇒
> `Failed to find primary plane` ⇒ 图形会话无法建立。

---

## 1. 症状（errno 级）

`drmplaneprobe` 实测（纯 TCG，`evidence/2026-09-22_t490-planeprobe`）：

```text
[PRES]  第一段 count_planes=1 rc=0 errno=0
[PRES]  第二段 rc=0 errno=0 count_planes=1 ids=64        ← GETPLANERESOURCES 正常
[PLANE] GETPLANE rc=-1 errno=95 ...                       ← ★ 相邻编号却完全不通
[PLANESUM] planes=1 type_attr=FOUND type_is_primary=YES in_formats_blob=4096 verdict=PLANE_OK
```

**关键判读**：`0xB5`（GETPLANERESOURCES）与 `0xB6`（GETPLANE）是**同一族、编号相邻**的两个 ioctl，
前者 `rc=0`、后者 `errno=95`（ENOTSUP = 未命中任何分派分支）。
⇒ 不是"plane 功能没实现"（枚举明明列出了 plane），而是**这一个 ioctl 的编码对不上**。

## 2. 根因：两侧结构体逐字段对比

内核 `io/drmdevice/src/drm.rs:222`：

```rust
pub struct DrmModeGetPlane {
    pub plane_id: u32,
    pub crtc_id: u32,
    pub fb_id: u32,
    pub possible_crtcs: u32,        // ← mainline 在这里还有 crtc_x/crtc_y/x/y
    pub gamma_size: u32,
    pub count_format_types: u32,
    pub format_type_ptr: UserPtr<u32>,
}                                   // = 6×4 + 8 = 32 B（对齐 8）
```

mainline `include/uapi/drm/drm_mode.h`：

```c
struct drm_mode_get_plane {
	__u32 plane_id;
	__u32 crtc_id;
	__u32 fb_id;
	__u32 crtc_x;      /* ← 内核缺 */
	__u32 crtc_y;      /* ← 内核缺 */
	__u32 x;           /* ← 内核缺 */
	__u32 y;           /* ← 内核缺 */
	__u32 possible_crtcs;
	__u32 gamma_size;
	__u32 count_format_types;
	__u64 format_type_ptr;
};                          /* = 10×4 + pad4 + 8 = 48 B */
```

而 `io/drmdevice/src/consts.rs:17` 的 `iowr<T>()` **把 `size_of::<T>()` 编进 ioctl 号**
（与 Linux `_IOWR` 语义一致）⇒ 内核侧期望 `nr=0xB6 size=32`，libdrm 发出 `nr=0xB6 size=48`
⇒ **编码不等** ⇒ 落到分派表末尾 `_ => Err(VfsError::OperationNotSupported)`（errno=95）。

## 3. 复现方法（评分要求"每条缺口附复现方法"）

```bash
# 主机侧交叉编译，注入 guest，宿主编排一轮纯 TCG 会话
aarch64-linux-musl-gcc -static -O2 -o drmplaneprobe scripts/t490/drmplaneprobe.c
bash scripts/t490/t490_round.sh planeprobe 240 60 autorun_plane.sh drmplaneprobe.c
```

探针判据行：`[PLANE] GETPLANE rc=… errno=…`，以及汇总行 `[PLANESUM]`。
探针自带 `VERSION` 自证 —— 若 `VERSION` 也不通，则说明探针自身编码有误，结论不可用。

## 4. 修复（`scripts/t490/p3_apply.sh`，幂等 + 字段顺序断言）

`io/drmdevice/src/drm.rs`：按 mainline 顺序补回四个字段（位置必须在 `fb_id` 之后、
`possible_crtcs` 之前，否则布局仍不匹配）；`card0.rs` 的 handle 里将其置 0
（语义为 plane 当前裁剪/位置，未启用时即为 0；Weston 不读这些字段，但**布局必须完整**）。

kernel.bin：`2105fc43…` → **`6ab03917…`**（`Compiling drmdevice` 可证）。

## 5. 验证

```text
[PLANE] GETPLANE rc=0 errno=0 crtc_id=16 fb_id=0 possible_crtcs=0x1 gamma_size=0 count_formats=2
```

| 观测项 | before | after |
|---|---|---|
| `GETPLANE` rc/errno | `-1 / 95` | **`0 / 0`** |
| `crtc_id` | `0`（未填充） | `16` |
| `possible_crtcs` | `0x0` | **`0x1`** |
| `count_formats` | 16（探针初值，内核未写） | `2` |

会话：`evidence/2026-09-22_t490-weston7`（纯 TCG，平台预检同前）。

> ⚠️ **该修复解决了 `GETPLANE`，但 Weston 仍未出画面** —— 说明 plane 创建还有**另一处**
> 静默失败（见 report/32）。本条缺口的价值独立于"是否立刻跑通图形"：
> 它是可复现、可验证、边界清晰的 uapi 契约缺陷。

## 6. 与缺口 A 的共性（系统性认识，重要）

| | 缺口 A | 缺口 D |
|---|---|---|
| 位置 | 属性面 `GETPROPERTY`/`GETPROPBLOB` | plane 面 `GETPLANE` |
| 错法 | **编号**挂错（0xAA↔0xA8、0xAC↔0xAA） | **结构体字段缺失**（32 B vs 48 B） |
| 共同机制 | `iowr<T>()` 把 `size_of::<T>()` 编进 ioctl 号 ⇒ 编号或大小任一对不上即失败 | 同 |
| 共同症状 | `errno=95` 落入 `_ =>` 默认分支 | 同 |

**⇒ 结论：`io/drmdevice` 的 uapi 对齐需要一次系统性核对**，
而不是"撞一个修一个"。建议的核对方式（可复用）：
**逐一比对内核 Rust 结构体与 `include/uapi/drm/*.h` 的字段序列与总长度**，
或直接用探针把"每个 ioctl 的命中情况"扫一遍（`errno=95` 即为未命中）。

## 7. 合规声明

- 全部结论来自 **T490 纯 TCG 会话**（`-m 2g -smp 4 -cpu cortex-a76`，命令行无 `-accel`），
  未混入 KVM/HVF 数据；证据目录为新建，未覆盖任何已完成 run；
- 修复脚本幂等且带**字段顺序断言**（顺序错则硬失败，防止"补了字段但位置不对"的假修复）；
- 本条缺口与缺口 A 都**不需要修改任何用户态**，是纯内核侧修复 —— 符合赛题"内核能力配置"的定位。
