# 30 · Weston 启动链的四层阻塞与真正根因：sysfs 未暴露 DRM 设备

> 日期：2026-09-22 晚 ｜ 轮次：weston1 → weston6（每轮一次纯 TCG 会话）
> **结论先行**：Weston 14 的 DRM backend **先用 libudev 去 `/sys/class/drm/<name>` 查设备**，
> 查不到就直接报 `ERROR: could not open DRM device` 并返回 —— **它根本不走到
> `open()` 或 `libseat_open_device()`**。本 guest 的 `/sys/class` 只有 `graphics`、
> **没有 `drm`**，因此无论给什么参数、用什么 launcher、有没有 seatd，都必然失败。
>
> 此前几轮围绕"参数形态 / 权限 / seatd 设备归属"的猜测**全部不是根因** ——
> 这点必须写清楚，否则会把后来的排查者引向错误方向。

---

## 1. 四层阻塞一览（每层都有实机证据）

| # | 轮次 | 阻塞点 | 关键证据 | 状态 |
|---|---|---|---|---|
| 1 | weston1 | `--drm-device=card0` 缺 `/dev/dri/` 前缀 | 报错**原样回显** `'card0'`（若 weston 自己拼接会显示完整路径） | 已修（改完整路径） |
| 2 | weston2 | guest `/run` **是持久化的**（非 tmpfs）；weston1 轮遗留的空壳 `seatd.sock` 被固化进基准镜像，骗过 `[ -S ]` 判据 ⇒ 跳过启动 seatd | 镜像内 `seatd.sock`（inode 57632、mode 140770、0 字节）；libseat 报 `Connection refused`（而非 `No such file`） | 已修（永远 `rm -f` 重启 + 改功能判据） |
| 3 | weston4 | `LD_PRELOAD` **逐符号**解析：shim 缺 `libseat_switch_session`/`set_log_handler`/`set_log_level` ⇒ 静默回退到真 libseat ⇒ 真库拿到假 seat | shim 日志只有 `open_seat`/`close_seat`，**永远等不到 `open(...)`**；`drm-backend.so` 的 UND 集合与 shim 导出集合差 3 个 | 已修（按真实符号表补齐 + 机器断言） |
| 4 | **weston5** | **根因**：weston 先用 **udev 查 sysfs** 才去开设备；`/sys/class/drm` 不存在 | 见 §3 的源码级证据 | 见 §5 |

> 说明：第 3 层与第 4 层是**串联**的 —— 第 3 层修好后（shim 符号齐了），
> `open_device` 依然不被调用，才暴露出第 4 层。**如果第 3 层没修，第 4 层看不见。**

---

## 2. 为什么前几轮的怀疑方向都是错的

这是本轮最值得记录的**方法论**部分。

| 曾经的怀疑 | 为什么看起来合理 | 实际为什么错 |
|---|---|---|
| `--drm-device` 需要完整路径 | weston1 报错回显 `'card0'` | 只是**第一层**；改成完整路径后（weston3）同样失败 |
| seatd 的设备归属判定拒绝（缺 sysfs/udev） | seatd.log 有 `Could not open tty0` 等一串错误 | seatd 确实有问题，但**weston 根本没走到请求设备那一步** —— seatd 侧从无 device 请求 |
| 需要 `libseat_shim` 绕过 | shim 的 `open_seat` 确实被调用了 | 符号不全导致静默回退；补齐后仍失败，说明**卡在更上游** |

**共性错误**：把"**离现场最近的报错**"当成"根因"，而没有先确认
**调用栈到底走到哪一步**。本轮真正解决问题的一步是**读 weston 源码**，
把 `could not open DRM device` 这条消息定位到 `drm.c:3707` 的具体函数 —— 一读就发现
它在 `libseat`/`open` 之前。

---

## 3. 真正根因：源码级证据

Weston 14.0.2，`libweston/backend-drm/drm.c:3697`：

```c
static struct udev_device *
open_specific_drm_device(struct drm_backend *b, struct drm_device *device,
			 const char *name)
{
	struct udev_device *udev_device;

	udev_device = udev_device_new_from_subsystem_sysname(b->udev, "drm", name);
	if (!udev_device) {
		weston_log("ERROR: could not open DRM device '%s'\n", name);   /* ← 我们看到的报错 */
		return NULL;
	}

	if (!drm_device_is_kms(b, device, udev_device)) { ... }
	...
}
```

以及调用方 `drm.c:4031`：

```c
	if (config->specific_device)
		drm_device = open_specific_drm_device(b, device, config->specific_device);
	else
		drm_device = find_primary_gpu(b, seat_id);
	if (drm_device == NULL) {
		weston_log("no drm device found\n");        /* ← 我们看到的第二行 */
		goto err_udev;
	}
```

**两条报错的先后顺序**（`could not open` → `no drm device found`）与源码完全吻合，
互相印证。

而设备真正被打开的动作在 `drm_device_is_kms()` 里（`drm.c:3557`）：

```c
	const char *filename = udev_device_get_devnode(udev_device);   /* ← 也要经过 udev */
	...
	fd = weston_launcher_open(compositor->launcher, filename, O_RDWR);
```

⇒ **两处入口都要经过 libudev。** `udev_device_new_from_subsystem_sysname()`
需要 `/sys/class/drm/<name>/` 及其 `uevent`/`dev` 等属性文件；
本 guest 的 `/sys/class` **只有 `graphics`**（weston2 轮实测），因此必然返回 NULL。

**这同时解释了 weston3/4 的两个"奇怪现象"**：
- 为什么 seatd 侧收不到任何 device 请求（weston 没走到）
- 为什么 `libseat_open_device` 从未被调用（同上）

---

## 4. 新内核缺口：DRM 设备未在 sysfs 暴露（缺口 C）

| 项 | 内容 |
|---|---|
| **现象** | `/sys/class/drm/` 不存在；`/sys/class` 仅含 `graphics` |
| **影响** | 任何经 libudev 找 DRM 设备的用户态（Weston 14、gdm、大多数现代合成器）**都无法启动**；`libinput` 同样无法枚举输入设备 |
| **复现方法** | guest 内 `ls /sys/class/` 与 `ls /sys/class/drm/`；或直接跑 `weston --backend=drm-backend.so` 观察报错 |
| **与赛题的对应** | 赛题原文要求"配置图形、输入、文件系统和网络所需**内核能力**"——**sysfs 暴露设备属于"文件系统所需内核能力"**，本缺口正落在这句话里 |
| **最小实现方向（待评估）** | 在 `io/drmdevice` 里为 DRM 设备注册 sysfs 节点：`/sys/class/drm/card0/`（含 `dev`＝`226:0`、`uevent`、`status`）与 `/sys/dev/char/226:0`；让 libudev 能枚举到设备。**工作量明显大于缺口 A（两行），需先做可行性评估。** |

**它的价值定位**：这是目前已知**最"硬"的一条缺口** ——
前两条（属性面编号错位、`CREATE_DUMB` 仅 32bpp）都只在特定路径上触发，
而这条**直接阻断所有标准用户态图形程序**。作为缺口清单条目，分量最重。

---

## 5. 用户态过渡方案：双 LD_PRELOAD shim

> **定位声明（按项目纪律）**：shim 属于**用户态过渡/诊断**手段，**不写入任何优化收益表**。
> 它的作用是：在"内核补 sysfs"这一正解完成之前，先把图形链路跑通、拿到 40 分的证据；
> 同时**反向证明**"除 sysfs 之外，DRM 侧的能力（属性面、dumb buffer、fb、crtc）已经够用"。

| shim | 作用 | 关键点 |
|---|---|---|
| `libseat-shim.so` | `open_seat` 返回假 seat；`open_device` 直接 `open(path)` | **延迟 100ms 回调 `enable_seat`**（同步回调会让 weston 在内部状态未就绪时继续） |
| `libudev-shim.so` | 假 udev 对象：`drm` 子系统查询恒命中；`get_devnode`→`/dev/dri/card0`、`get_sysnum`→`"0"`、`get_devnum`→`226,0`；枚举恒空 | 用 **version script** 导出为 `LIBUDEV_183`（消费者引用的是**带版本**符号） |

### 5.1 本轮新增的方法论：符号覆盖机器断言

`scripts/t490/build_shims.sh` 把这条教训固化成了断言：

```
引用集（consumer 的 UND 符号，strip @版本） ⊆ 提供集（shim 导出符号）
```

任一符号缺失即**硬失败**，不允许起会话。理由：
**缺失的符号不会报错，只会让真库被静默调用**，然后以一个完全无关的症状（"设备打不开"）浮现。
本项目的 `libseat_shim` v5 就是这么浪费掉一轮的。

实测结果：

```
OK  drm-backend.so 的 libseat 符号（10 个）全部覆盖
OK  drm-backend.so 的 udev   符号（26 个）全部覆盖
SYMBOL_COVERAGE_OK
```

---

## 6. 待验证与边界

- 双 shim 的最终效果由 weston6 轮验证（本轮记录时该轮尚在运行）；**未通过前不得宣称图形链路已通**；
- `/sys/class` 的完整内容只取样到 `graphics` 一项，是否还存在其它被内核注册的 class 未逐一枚举；
- 缺口 C 的"最小 sysfs 实现"尚未做可行性评估（x-kernel 的 sysfs 机制、`KFEAT_FS_SYSFS` 能力面未查）；
- 本轮所有结论均来自 T490 纯 TCG 会话（`-m 2g -smp 4 -cpu cortex-a76`，无 `-accel`），未混入 KVM/HVF。

## 7. 附：本轮新增/变更的脚本

| 文件 | 用途 |
|---|---|
| `scripts/t490/drmpropprobe.c` | 属性面 uapi 探针（缺口 A 的复现方法） |
| `scripts/t490/autorun_prop.sh` | 探针轮 guest 侧编排 |
| `scripts/t490/libseat_shim.c` | libseat shim（v6：符号齐 + 延迟回调） |
| `scripts/t490/libudev_shim.c` | libudev shim（假 udev 对象） |
| `scripts/t490/libudev_shim.map` | 符号版本脚本（`LIBUDEV_183`） |
| `scripts/t490/build_shims.sh` | 编译 + 多库符号覆盖断言 + 打包 |
| `scripts/t490/p2_apply.sh` | 缺口 A 的两行修复（幂等 + 形态断言） |
| `scripts/t490/patch_round_assert_logs.py` | 把新 guest 日志登记进回收清单（幂等） |
| `scripts/t490/autorun_weston{,2,3,4,6}.sh` | 各轮 Weston 启动编排 |
