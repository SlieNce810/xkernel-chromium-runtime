# 29 · 缺口 A 修复闭环：KMS 属性面 ioctl 编号对齐 Linux uapi

> ## ⛔ 勘误（2026-09-22 深夜）：本文的"修复"本身是误修，已撤销
>
> 经对 **guest 自带 uapi 头 `drm.h:1159-1164` 逐行核对**：
> `0xA8` 是 `DRM_IOCTL_MODE_ATTACHMODE`（**deprecated, never worked**）、
> `0xAA` 才是 `DRM_IOCTL_MODE_GETPROPERTY`、`0xAC` 才是 `DRM_IOCTL_MODE_GETPROPBLOB`。
> ⇒ **内核 HEAD 的原始编号（GETPROPERTY=0xAA、GETPROPBLOB=0xAC）本来就是 uapi 值**，
> 本文把 `0xAA→0xA8`、`0xAC→0xAA` 的替换**把两个正确编号改坏了**。
>
> 后果（有完整机器证据）：真实 libdrm 的 `drmModeGetProperty` 发 `req=0xc04064aa`，
> 改坏后内核只认 `0xc04064a8` ⇒ `errno=95` ⇒ Weston 读不到任何属性名 ⇒
> `plane->type = COUNT` ⇒ `drm_plane_create()` 静默丢弃 ⇒
> **`Failed to find primary plane for output Virtual-1`**（即本文之后几轮一直卡住的那一句）。
>
> 与本文自称的 `BROKEN → FIXED` 对照之所以成立，是因为**探针 `drmpropprobe.c` 与内核用了
> 同一套错编号**（自洽 ≠ 正确）—— 与缺口 D（report/32）属于同一类失效模式。
>
> 回退：`scripts/t490/p2_revert.sh`；回退后 `card0.rs` 与 HEAD 逐字节一致；
> 之后 weston11 轮出现首个真实首帧（`Output 'Virtual-1' enabled` + 1280×800 + 画面在重绘）。
> **完整勘误、因果链与 before/after 见 [report/33](33-勘误-缺口A修复本身是误修-它才是primary-plane失败根因.md)。**
> **阅读本文前请先读 report/33。** 原文保留不改，作为"自洽陷阱"的实例。

> 日期：2026-09-22（晚）
> 触发：report/28 §6 的补丁次序 P2「KMS 属性面编号修复」
> 结论：**缺口 A 已修复并通过 errno 级 before/after 对照**。
> 改动 2 行；kernel.bin 哈希可追溯；对照实验在同一镜像、同一探针、同一会话参数下完成，
> 唯一变量 = kernel.bin。

---

## 1. 缺口定义与复现方法

### 1.1 缺口原文（report/28 §4.1，本轮已从"推论"升级为"实测"）

x-kernel 的 `io/drmdevice` 把属性面两个 ioctl 挂在了与 Linux uapi 不符的编号上：

| mainline 编号 | mainline 语义 | x-kernel 修复前 | 后果 |
|---|---|---|---|
| `0xA8` | `DRM_IOCTL_MODE_GETPROPERTY`（`drm_mode_get_property`，64 B） | **完全缺失** | libdrm `drmModeGetProperty()` → `ENOTSUP(95)` |
| `0xAA` | `DRM_IOCTL_MODE_GETPROPBLOB`（`drm_mode_get_blob`，16 B） | 挂着 **64 B 的属性结构** | 尺寸不匹配，`drmModeGetPropertyBlob()` → `ENOTSUP` |
| `0xAC` | mainline 未分配 | 挂着 blob 处理器 | 任何 Linux ABI 客户端都到不了 → 死代码 |

机制在 `io/drmdevice/src/consts.rs:17`：`iowr<T>()` 把 `size_of::<T>()` 编进 ioctl 号
（与 Linux `_IOWR` 语义一致）⇒ **编号与结构大小双重错配** ⇒ 请求落到分派表末尾的
`_ => Err(kvfs::VfsError::OperationNotSupported)` ⇒ `errno = 95`。

### 1.2 复现方法（评分要求"每条缺口附复现方法"）

```bash
# 宿主机交叉编译，注入 guest，在 guest 内执行
aarch64-linux-musl-gcc -static -O2 -o drmpropprobe scripts/t490/drmpropprobe.c
# 见 scripts/t490/autorun_prop.sh（t490_round.sh 会自动注入并拉起）
bash scripts/t490/t490_round.sh propbefore 300 60 autorun_prop.sh drmpropprobe.c drmdumbprobe.c
```

探针输出判定行 `[PROPSUM] … verdict=BROKEN|FIXED`，宿主侧 `grep` 即得结论。

---

## 2. 探针设计：为什么它不是普通探针

三处刻意设计，缺一条证据链就不闭合：

1. **判据不是 `rc` 而是"errno 是否为 95"**。
   `ENOTSUP(95)` = 没命中任何分派分支；`EINVAL/ENOENT` = 命中了处理器、只是参数/对象无效。
   所以「95 vs 非 95」直接等价于「编号对不对得上」，与属性内容无关。

2. **双向对照（A 组 mainline 编号 / B 组 x-kernel 现用编号）**。
   只测 A 组只能得到"不工作"；加上 B 组才能区分
   「内核**没实现**属性面」与「内核实现了、但**挂错编号**」——两者是完全不同的缺口定性，
   后者才是可用两行修复的那一类。

3. **链式验证 = libdrm 的真实调用序列**：
   `GETRESOURCES → GETCONNECTOR → OBJ_GETPROPERTIES → GETPROPERTY(真实 prop_id)`。
   这是 Weston DRM backend 建立 output 时必经的路径；断在哪一环，就是用户态起不来的那一环。
   **并且 step=5 与 step=5b 用同一个 prop_id**，唯一差别是 ioctl 编号 ⇒ 控制变量实验。

4. **自证**：先跑 `VERSION(0x00)`（已知可通）。若它也不通，则说明探针自身的 `_IOWR`
   编码有误，此后所有结果**不得**解读为内核缺陷 —— 避免"探针缺陷被误记为内核缺陷"。

---

## 3. before 证据（基线 kernel.bin `66559c13…`，2026-09-22 12:15 构建）

会话：`evidence/2026-09-22_t490-propbefore/`（纯 TCG，平台合规 36/36 + 15/15）

```text
[PROP] A1  GETPROPERTY@0xA8/64B   rc=-1 errno=95 (Not supported) NOT-DISPATCHED(errno=95)
[PROP] A2  GETPROPBLOB@0xAA/16B   rc=-1 errno=95 (Not supported) NOT-DISPATCHED(errno=95)
[PROP] B1  GETPROPERTY@0xAA/64B   rc=-1 errno=2  (No such file or directory) HIT(errno!=95)
[PROP] B2  GETPROPBLOB@0xAC/16B   rc=-1 errno=2  (No such file or directory) HIT(errno!=95)
[CHAIN] step=1 GETRESOURCES(count) rc=0  fbs=0 crtcs=1 conns=1 encs=1
[CHAIN] step=2 GETRESOURCES(ids)   rc=0  connector_id=48 crtc_id=16
[CHAIN] step=3 GETCONNECTOR        rc=0  connection=1 encoder_id=32 count_props=0 count_modes=1
[CHAIN] step=4 OBJ_GETPROPERTIES   rc=0  count_props=1 prop_ids[0..3]=768,0,0,0
[CHAIN] step=5  GETPROPERTY@0xA8(prop_id=768) rc=-1 errno=95 ← Weston 会死在这一步
[CHAIN] step=5b GETPROPERTY@0xAA(prop_id=768) rc=0           ← 同一 prop_id，旧编号竟 rc=0
[PROPSUM] mainline_property=NOT-DISPATCHED mainline_blob=NOT-DISPATCHED \
          xkernel_property=HIT xkernel_blob=HIT chain_max_step=4 verdict=BROKEN
```

要点：
- **A 组全灭（errno=95）、B 组全中（errno≠95）** ⇒ 处理器存在、只是编号挂错（不是"未实现"）。
- **step=5 与 step=5b 的对比**排除了"prop_id 不对"的干扰：
  同一 `prop_id=768`，`0xA8` 得到 95，`0xAA` 得到 `rc=0`。**纯编号差异**。

---

## 4. 修复（scripts/t490/p2_apply.sh）

`io/drmdevice/src/card0.rs`，两行：

```diff
 impl DrmIoctl for DrmModeGetProperty {
-    const CMD: u32 = iowr::<DrmModeGetProperty>(DRM_TYPE, 0xAA);
+    const CMD: u32 = iowr::<DrmModeGetProperty>(DRM_TYPE, 0xA8);

 impl DrmIoctl for DrmModeGetBlob {
-    const CMD: u32 = iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAC);
+    const CMD: u32 = iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAA);
```

**改动前的安全性核对（逐条）**：

| 核对项 | 结论 |
|---|---|
| `0xA8` 是否已被占用 | 全仓扫描 `io/ core/ drivers/` 的全部 `*.rs` ⇒ **空闲**，无冲突 |
| `0xAC` 迁走后是否留空 | mainline 未分配该编号 ⇒ 不产生新的错位 |
| 结构体大小是否等于 mainline | `DrmModeGetProperty` = 64 B、`DrmModeGetBlob` = 16 B，逐字段一致（`drm.rs:251/327`） |
| 是否还有其他硬编码编号 | 全仓仅这两处出现 `0xAA`/`0xAC` 的 DRM 编号用法 |
| 分派表是否自动跟随 | 是 —— match 用 `<T as DrmIoctl>::CMD` 常量，改常量即改分派 |

编译（`make build`，非全流程重建；不触碰 rootfs / disk.img）：

```text
Compiling drmdevice v0.3.0-dev        ← 改动的 crate 确实被重编
Compiling devfs / fs_boot / kruntime / kfeat / entry   ← 依赖链
Finished `release` profile [optimized] target(s) in 6.60s
Built /home/mo/x-kernel/target/xkmake/kplat-aarch64/release
```

kernel.bin：`66559c13…`（12:15）→ **`2105fc43…`**（19:54）。大小同为 8,258,816 B（仅常量值变化）。

---

## 5. after 证据（修复后 kernel.bin `2105fc43…`）

会话：`evidence/2026-09-22_t490-propafter/`
**与 before 唯一的差异 = kernel.bin**（同 BASE_IMG、同探针、同 autorun、同平台参数）。

```text
[PROP] A1  GETPROPERTY@0xA8/64B   HIT    ← 修复生效
[PROP] A2  GETPROPBLOB@0xAA/16B   HIT
[PROP] B1  GETPROPERTY@0xAA/64B   NOT-DISPATCHED(errno=95)  ← 旧编号如期失效（反向确认）
[PROP] B2  GETPROPBLOB@0xAC/16B   NOT-DISPATCHED(errno=95)
[CHAIN] step=5  GETPROPERTY@0xA8(prop_id=768) rc=0 errno=0 flags=0x80000040 count_values=0
[CHAIN] step=5b GETPROPERTY@0xAA(prop_id=768) rc=-1 errno=95
[PROPSUM] mainline_property=HIT mainline_blob=HIT \
          xkernel_property=NOT-DISPATCHED xkernel_blob=NOT-DISPATCHED \
          chain_max_step=5 verdict=FIXED
```

`flags = 0x80000040` = `DRM_MODE_PROP_ATOMIC(1<<31) | DRM_MODE_PROP_OBJECT(1<<6)`
—— 正是 connector 的 **CRTC_ID 属性**应有的标志位，说明内核不仅让编号命中了，
而且真的填充了属性元数据（不是空壳响应）。

> 备用证据（本轮 Weston 轮的 A 小节）：修正版探针把 `name` 字段一并打出，
> 用于确认 `prop_id=768` 的名字。上一版探针打印的是错误的缓冲区，故 before/after
> 那一版证据里 `name=''` —— **该空串是探针缺陷，不是内核缺陷**，rc/errno 判据不受影响。

## 5.1 before / after 对照总表

| 观测项 | before | after | 判定 |
|---|---|---|---|
| `GETPROPERTY@0xA8`（mainline） | errno=95 | **HIT** | ✅ 修复 |
| `GETPROPBLOB@0xAA`（mainline） | errno=95 | **HIT** | ✅ 修复 |
| `GETPROPERTY@0xAA`（旧编号） | HIT | NOT-DISPATCHED | ✅ 如期失效 |
| `GETPROPBLOB@0xAC`（旧编号） | HIT | NOT-DISPATCHED | ✅ 如期失效 |
| 链式 `chain_max_step` | 4（断在 GETPROPERTY） | **5（全通）** | ✅ 打通 |
| `verdict` | **BROKEN** | **FIXED** | ✅ |

**对既有缺口清单的连带影响**：既有缺口清单第 2 条 `WESTON_DISABLE_ATOMIC=1`
（"atomic KMS 实际不可用或不可靠"）的**根因即为本缺口** —— 官方启动器不得不写这个环境变量，
不是因为 atomic 不稳定，而是因为**属性查询这一层在内核里是断的**（atomic commit 必须能读属性）。
本条从"现象描述"升级为"根因 + 复现 + 修复"，分量提高。

---

## 6. 附带发现（新缺口候选，本轮**未改**，保持单一变量）

`GETCONNECTOR`（step=3）与 `OBJ_GETPROPERTIES`（step=4）对同一 connector 报告的属性数量**不一致**：

```text
[CHAIN] step=3 GETCONNECTOR      … count_props=0
[CHAIN] step=4 OBJ_GETPROPERTIES … count_props=1 prop_ids[0]=768
```

libdrm 的 `drmModeGetConnector()` 会用 `count_props` 决定属性数组的分配与二次取数。
若内核恒返回 0，走 `drmModeGetConnector` 路径的客户端会拿到"零属性"的 connector。

**定性待补**：需要确认 Weston / Xorg 实际走的是 `drmModeGetConnector`（会踩到）
还是 `drmModeObjectGetProperties`（不受影响）。本轮先记录，不修改 ——
避免与属性面修复混在同一轮里，破坏可归因性。

### 6.1 官方启动器在 Weston 14 上的参数失效（weston1 轮实测）

装好 Weston 14.0.2 后按**官方 `xk-weston-start` 的原参数**启动，失败：

```text
[12:03:11.015] initializing drm backend
[12:03:11.016] Trying libseat launcher...
[12:03:11.033] [libseat/libseat.c:73] Seat opened with backend 'seatd'
[12:03:11.034] libseat: session control granted          ← 授权通路完全正常
[12:03:11.040] ERROR: could not open DRM device 'card0'  ← 打开的是字面量 "card0"
[12:03:11.040] no drm device found
[12:03:11.045] fatal: failed to create compositor backend
```

**判读**：Weston 14 把 `--drm-device` 的值交给 launcher
（libseat `libseat_open_device(seat, path, &fd)`），此处 `path` 须为**设备路径**。
报错原样回显 `'card0'`（而非拼接后的 `/dev/dri/card0`）⇒ Weston 没有做 `/dev/dri/` 前缀拼接。
官方脚本的 `--drm-device=card0` 在 Weston 14 + libseat/seatd 组合下不成立。

**同轮已确认可用的部分**（避免把成功项当失败项重查）：

| 项 | 实测 |
|---|---|
| `apk add` 装包（清单取自官方脚本） | `rc=0`；weston/seatd/weston-simple-shm/xterm/xclock 全部落地 `/usr/bin/` |
| 依赖完整性 | `ldd /usr/bin/weston` 无 `not found` |
| 镜像空间 | 装后 `/` 使用 50%（925.8M / 1.9G，余 917.6M） |
| seatd | 起来且 `/run/seatd.sock` 就位 |
| libseat ↔ seatd | `Seat opened with backend 'seatd'` + `session control granted` |
| `/run/user/0`（XDG_RUNTIME_DIR） | 可写 |

⇒ 阻塞点已收敛为**单一参数**：`--drm-device` 的取值形态。
下一轮按「完整路径 → 无参数 → 去 seat → builtin 后端」四方案定位（`autorun_weston2.sh`）。

### 6.2 x-kernel guest 的 `/run` 是持久化的 —— 以及一个自伤的假门禁（weston2 轮）

**现象**：weston2 轮（BASE_IMG = 已固化的 `agentos-weston.img`）**四个方案全部失败**，且失败原因
与 weston1 完全不同：

```text
[libseat/backend/seatd.c:66] Could not connect to socket /run/seatd.sock: Connection refused
[libseat/libseat.c:76] Backend 'seatd' failed to open seat, skipping
[libseat/backend/logind.c:621] Could not get primary session for user: No data available
[libseat/libseat.c:79] No backend was able to open a seat
fatal: your system should either provide the logind D-Bus API, or use seatd.
```

而同一个 seatd 通路在 weston1 轮是**成功**的（`Seat opened with backend 'seatd'` +
`session control granted`）⇒ 不是 seatd 本身不可用，而是**这一轮它根本没被启动**。

**根因（两层，都要记）**：

1. **guest 的 `/run` 是持久化目录，不是 tmpfs**。
   用 `debugfs` 只读检查固化的镜像，`/run` 下确实存在 weston1 轮运行期创建的文件：

   ```text
   /run/seatd.sock   inode 57632  mode 140770(socket)  0 字节  22-Sep 20:03   ← 陈旧空壳
   /run/user/0/.wtest                                           ← weston1 的写测试残留
   ```

   即 `cp disk.img images/agentos-weston.img` 把**运行期状态**一起固化进了基准镜像。

2. **我自己的门禁是个假门禁**。`autorun_weston2.sh` 用

   ```sh
   if [ ! -S /run/seatd.sock ]; then 启动 seatd; fi
   ```

   判断"是否需要启动 seatd"。第 1 条的陈旧 socket 文件让 `-S` 为真 ⇒ **跳过启动** ⇒
   libseat 连上一个没有监听者的 socket。注意报错是 **Connection refused 而不是
   No such file** —— 这正是"文件在、监听者不在"的指纹，可惜当时先被当作"seatd 起不来"。

**教训（升级为纪律）**：

> **不要用"文件是否存在"判断"服务是否可用"。** 可用判据只有两种：
> ① **进程存活**（`/proc/<pid>`）；② **功能可用**（实际连接或请求成功）。
> 本项目的同一条教训此前已针对 Xorg 立过一次（`socket 存在 ≠ Xorg 可用`，见 report/27），
> 这次在 seatd 上**重犯** ⇒ 该纪律必须落到**所有** daemon 类检查上，不只图形会话。

修复（`autorun_weston3.sh`）：**永远** `rm -f` 陈旧 socket 并重启 seatd，
判据改为「seatd 进程存活 → 由 weston 实际连接成功」这条功能链。

### 6.3 同轮采集的另两项能力事实

| 事实 | 实测 | 影响 |
|---|---|---|
| `/dev/input` 为空 | `ls -la /dev/input/` 无任何输出 | virtio-input **未注册 event 节点**（记忆中的 `event0`/`mice` 在 agentos 镜像上不成立）⇒ G6 缺口仍在；Weston 靠 `--continue-without-input` 兜住 |
| `/sys/class` 只有 `graphics`，无 `drm` | `/sys/class/drm` 不存在 | libudev 枚举通路不可用 ⇒ Weston **只能**走显式 `--drm-device` 路径（这解释了为什么参数形态成了阻塞点） |
| `/dev/dri/card0` | `crw-rw-rw- 226,0` | 设备节点正常，major 226 = 标准 DRM major |
| `/dev` 挂载 | `devtmpfs` | 设备节点由内核填充，非静态 |

---

## 7. 合规声明

- 全部"已实测"结论来自 **T490 上纯 TCG 会话**（`-m 2g -smp 4 -cpu cortex-a76`，命令行
  **无 `-accel`**），平台预检 36/36 + 运行期 15/15，未混入任何 KVM/HVF 数据；
- 两轮会话使用**同一份 BASE_IMG**（`images/agentos-disk.img`，sha256 `cfb24123…`），
  注入同一份探针与 autorun ⇒ 唯一变量是 kernel.bin；
- `p2_apply.sh` 幂等且带形态断言（改前后都打印实际行）；所有证据目录为新建，未覆盖任何已完成 run；
- 尚未闭环的两点已显式标注：§6 的行为差异定性、以及修复对 Weston 的实际解锁效果（见 report/30）。
