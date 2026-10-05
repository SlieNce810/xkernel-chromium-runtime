# 33 · 根因定位：「缺口 A」的修复本身是误修 —— 它才是 `Failed to find primary plane` 的根因

> 日期：2026-09-22 深夜 ｜ 性质：**勘误 + 根因定位**
> 关联：[report/29](29-缺口A修复闭环-DRM属性面编号对齐uapi.md)（其"修复"被本文推翻）、
> [report/32](32-勘误-GETPLANE-48字节结论错误与缺口D撤销.md)（同类错误的先例）
> 证据：`evidence/2026-09-22_t490-{prop2,prop3,weston9,weston10,weston11}`
> 工具：`scripts/t490/{proptwostage.c, weston_sim.c, iocspy.c, p2_revert.sh}`

---

## 1. 结论

**`Failed to find primary plane for output Virtual-1` 的根因是「缺口 A 的修复」本身。**
该修复把两个**本来正确**的 ioctl 编号改坏了：

| 编号 | uapi 真实含义（guest 自带 `drm.h:1159-1164` 逐行核对） | 内核 HEAD（原始） | 「缺口 A 修复」后 |
|---|---|---|---|
| `0xA8` | `DRM_IOCTL_MODE_ATTACHMODE`（**deprecated, never worked**） | — | 被当作 GETPROPERTY ✗ |
| `0xA9` | `DRM_IOCTL_MODE_DETACHMODE`（deprecated） | — | — |
| `0xAA` | **`DRM_IOCTL_MODE_GETPROPERTY`** | ✅ 挂在 0xAA（正确） | 被改成 GETPROPBLOB ✗ |
| `0xAB` | `DRM_IOCTL_MODE_SETPROPERTY` | — | — |
| `0xAC` | **`DRM_IOCTL_MODE_GETPROPBLOB`** | ✅ 挂在 0xAC（正确） | 丢失 ✗ |

⇒ **HEAD 的原始值是 uapi 值**；`0xA8`/`0xA9` 在 KMS 里是被跳过的废弃编号。

## 2. 完整因果链（每一步都有机器证据）

```text
① 内核把 GETPROPERTY 从 0xAA 改到 0xA8（p2_apply.sh）
        ↓
② 真实 libdrm 的 drmModeGetProperty 发出 _IOWR(0xAA, struct drm_mode_get_property)
   —— 机器证据（prop3 轮，iocspy）：
        [IOC] req=0xc04064aa dir=3 size=64 type=0x64 nr=0xaa -> rc=-1 errno=95(Not supported)
   （对照组：手写标准布局的两段式调用 req=0xc04064a8 反而"成功"——因为它跟着内核改了）
        ↓
③ libdrm 的 drmModeGetProperty 对**全部 12 个属性**返回 NULL（prop3 轮：OK=0 FAILED=12）
        ↓
④ Weston 的 drm_property_info_populate() 因此一个属性名都拿不到
   （weston_sim 复现：`[prop 0..11] drmModeGetProperty FAILED`）
        ↓
⑤ plane->type 取默认值 WDRM_PLANE_TYPE__COUNT(4)
   （drm.c:1213 的 `if (plane->type == WDRM_PLANE_TYPE__COUNT) goto err_props;` —— **不打日志**）
        ↓
⑥ drm_plane_create() 返回 NULL ⇒ create_sprites() 裸 `continue`（**静默**）
        ↓
⑦ device->plane_list 为空 ⇒ find_special_plane() 永远找不到 PRIMARY
        ↓
⑧ `Failed to find primary plane for output Virtual-1` ⇒ 输出无法启用
```

## 3. 为什么当时会被判成「BROKEN → FIXED」

**与缺口 D 完全相同的失效模式**：

| 环节 | 缺口 D（report/32） | 缺口 A（本文） |
|---|---|---|
| 错误前提 | 「GETPLANE 标准是 48 字节」 | 「GETPROPERTY 标准是 0xA8」 |
| 依据来源 | 对 uapi 的**记忆/误读**，未查头文件 | 同上 |
| 验证探针 | `drmplaneprobe.c` 用了同一套错布局 | `drmpropprobe.c` 用了同一套错编号 |
| 结果 | 探针与内核**自洽** ⇒ 变绿 | 探针与内核**自洽** ⇒ `BROKEN → FIXED`、`chain_max_step 4 → 5` |
| 真正的判据 | 标准客户端（libdrm） | 标准客户端（libdrm） |

⇒ **手写探针与内核用同一套约定时，"探针通过"只是自洽性证明，不是正确性证明。**

## 4. 回退与验证

**回退**：`scripts/t490/p2_revert.sh`（恢复 `GETPROPERTY=0xAA`、`GETPROPBLOB=0xAC`）；
执行后 `io/drmdevice/src/card0.rs` 与 HEAD **逐字节一致**（`git diff --stat` 只剩 `drm.rs` 的说明注释）。
内核：`a24ae553…` → **`398923f0…`**。

**验证（weston11 轮，同一探针/镜像/命令行，只换内核）**：

| 判据 | 改坏时（weston9/10） | 回退后（weston11） |
|---|---|---|
| `weston_sim` 复现 Weston 的 plane 创建 | `dropped_by_weston=1`、`verdict=SIM_PLANE_DROPPED`（12 个属性全读不到） | **`SIM_OK`**：12 个属性全部可读，`type=1(PRIMARY) {Overlay=0,Primary=1,Cursor=2}` |
| Weston 日志 | `Failed to find primary plane for output Virtual-1` | **该行消失**；出现 `Output 'Virtual-1' enabled with head(s) Virtual-1` |
| 输出模式 | 无（QEMU 屏幕恒 640×480） | **1280×800**（`DRM: output Virtual-1 uses shadow framebuffer` + `Output Virtual-1 (crtc 16) video modes: current@60.0`） |
| 画面内容 | `Display output is not active.` | **有内容**：截图主色为 `#7c7572`/`#8a8481` 灰褐渐变（桌面 shell 背景） |
| 帧间变化（心跳） | `changed_pixels=0`（帧全同） | **`changed_pixels` 86/85/164/86/72**，bbox 在右上角 ⇒ 时钟在重绘 |
| 客户端 | — | `weston-desktop-shell` 与 `weston-keyboard` 被拉起并连上 |

**结论**：在**无任何 shim** 的前提下（真实 libudev 内核 sysfs + 真实 seatd FD 传递），
Weston 已能启用输出并持续绘制。这是本赛题图形链路的**首个真实首帧里程碑**。

## 5. 纪律（第二次教训，已固化为规则）

1. **任何 ABI「修复」在动手前，必须先对权威头文件逐行核对**（`echo '#include <drm.h>' | gcc -E` 或直接 grep 宏定义）；
   不许凭记忆（`0xA8=GETPROPERTY` 就是记错的）。
2. **判据必须是"标准客户端"**（libdrm / libudev / libseat 等真实库），
   手写探针只用于**定位**，不用于**宣布修好**。
3. 探针输出必须带**自证行**（`[PROBE_ABI]` 之类）与**机器可读结论行**（`[PROBE_EXIT] veredict=…`），
   并纳入轮后门禁（`round_assert` ③.5）。
4. 每处"修复"必须留**标准客户端的 before/after**，且 before/after 之间只允许改一个变量（此处：只有内核）。

## 6. 证据索引

| 轮次 | 内容 | 关键文件 |
|---|---|---|
| `prop2` | 两段式逐段定位（call#1/call#2 全通 vs libdrm 12/12 失败） | `guest/_root_prop2.out` |
| `prop3` | **ioctl 请求值对照**（决定性）：`libdrm → req=0xc04064aa → errno=95` | `guest/_root_prop3.out` |
| `weston10` | `weston_sim` 复现 Weston：12 个属性全读不到 ⇒ 静默丢弃 plane | `guest/_root_weston10-sim.out` |
| `weston11` | **回退后验证**：`SIM_OK` + `Output enabled` + 1280×800 + 画面有内容 + 帧间变化 | `guest/_root_weston11-*.log`、`screenshots/*.ppm` |

## 7. 合规声明

- 全部结论来自 T490 纯 TCG 会话（`-m 2g -smp 4 -cpu cortex-a76`，命令行无 `-accel`），未混入 KVM/HVF；
- 回退脚本幂等且带形态断言（两个编号都必须回到 uapi 值，否则硬失败）；
- 未删除任何历史证据：report/29 原文保留，其顶部已加勘误横幅；
- 本轮的"无 shim"是可核验的：`LD_PRELOAD` 显式打印为空，且设备发现/设备打开分别由
  内核 sysfs 投射与 seatd 的真实 FD 传递承担（std3 轮已各自独立验证）。
