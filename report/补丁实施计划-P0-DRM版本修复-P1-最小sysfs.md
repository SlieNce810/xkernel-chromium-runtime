# 补丁实施计划：P0（DRM_IOCTL_VERSION NULL 处理）+ P1（最小 sysfs）

> 版本：v1.1（2026-09-21 收口更新）· 编制：小格（赛题六 · 基础任务 · 兼容性缺口与补丁）
> 依据：T490 实测证据（`report/T490验证测试记录-2026-09-21.md`）+ 源码侦察记录（本文附录）
> **技术约束（保持不变）**：AArch64 + QEMU ≥8.0 + 纯 TCG；全部改动仅在内核源码（git 可追溯），
> 不依赖宿主机 sudo；所有验证数据出自 T490 原生 Linux。

---

## ⚠️ 执行状态（2026-09-21 12:00 更新，执行结果与计划偏差说明）

| 阶段 | 计划 | **实际结果** | 状态 |
|---|---|---|---|
| **P0** 修 `DRM_IOCTL_VERSION` NULL 处理 | 改 `card0.rs` → 编译 → drmprobe 验证 | **完全按计划执行**：commit **`8162e8a`**、tag **`p0-drm-version-fix`**；验收 A1–A6 全过；镜像冻结 `images/p0-drmversion-fixed.img` | ✅ **完成** |
| **P1** 最小 sysfs（新建 crate） | 新建 `fs/filesystems/sysfs/` + `fs/boot` 挂载 + workspace 注册 | **路线修正**：侦察发现 **x-kernel 已有 sysfs**（`memfs::SYSFS_TYPE`，ramfs 实现，已挂 `/sys` 且运行时可写）→ **未新建 crate**，改为「运行时伪造 sysfs」过渡方案（`autorun fake_sysfs`：`/sys/class/drm/card0/{uevent,dev,subsystem}` + `/sys/dev/char/226:0/device/subsystem`） | ⚠️ **部分达成**：weston DRM compositor 成功运行（`Output 'Virtual-1' enabled`），但客户端因 **G4（SCM_RIGHTS fd 传递）** 阻塞 |

**执行中新增的两个关键结论**（已并入 §7 缺口登记与后续计划）：
1. **`--drm-device` 必须用简写 `card0`**：weston 将该值原样传给
   `udev_device_new_from_subsystem_sysname(udev, "drm", name)`；传绝对路径会拼出非法 syspath（`/sys/class/drm//dev/dri/card0`）→ NULL。
2. **正式 P1 的正确形态**：既然 `memfs::SYSFS_TYPE` 已是"内核填充的树"（源码注释明示
   *the directory tree is owned by this superblock*），**推荐做法是在挂载期或设备注册回调中由内核填充
   `/sys/class/drm/*` 与 `/sys/dev/char/*` 节点**，而非新增独立 fs crate；用户态伪造仅作过渡与验证手段。

---

## 0. 总览

### 目标
| 阶段 | 一句话目标 | 价值 |
|---|---|---|
| **P0** | 修复 `DRM_IOCTL_VERSION` 对 NULL/0 长度指针的处理，使 libdrm 的 `drmGetVersion` 正常工作 | 数行改动，打通 libdrm 基础调用；**上游补丁素材** |
| **P1** | 为 x-kernel 新增最小 sysfs（覆盖 `/sys/class/drm/card0/{dev,device/*}` 及 uevent），使 weston 14 的 DRM backend 直连 | 打通图形链路的**正解**，图形 20 分的关键路径 |

### 依赖关系
```
P0 (libdrm 基础调用正常)
   └─► P1 (sysfs → libdrm 枚举 → weston 发现设备)
         └─► 后续：weston 长稳 + Chromium 渲染（图形 20 + 浏览器 20）
```
> P0 是 P1 的前置：libdrm 是所有 libdrm 客户端（含 weston）的公共依赖，
> 若 `drmGetVersion` 持续 EFAULT，即使 sysfs 就绪，libdrm 的其他调用仍可能踩同类坑。

### 现状基线（修复前，已固化于冻结镜像）
- 冻结镜像：`~/x-kernel/images/dev-t490-debug-baseline.img`（sha256 `e01afe6e…`，含全部调试工具）
- `drmprobe v2` 实测：
  - `drmGetVersion(fd=3) -> NULL errno=14 (Bad address)` ← P0 要修
  - `drmGetDevices2(0, buf, 8) -> 0 errno=2 (ENOENT)`      ← P1 要修
- weston 14 报 `could not open DRM device '/dev/dri/card0'`（卡在 `udev_device_new_from_subsystem_sysname()`）

---

## 1. P0 阶段：修复 DRM_IOCTL_VERSION 的 NULL/0 长度指针处理

### 1.1 根因（源码定位，已核实）
`io/drmdevice/src/card0.rs` 第 126–146 行 `impl DrmIoctl for DrmVersion::handle`：
```rust
fn handle(_dev: &Card0, version: &mut Self) -> VfsResult<usize> {
    version.version_major = DRIVER_VERSION_MAJOR;
    ...
    version.name_len = DRIVER_NAME.len();
    version.name.write_vm_slice(DRIVER_NAME.as_bytes())      // ← 无条件 copy_to_user
        .map_err(|_| VfsError::BadAddress)?;                 // ← name=NULL 时 → BadAddress → EFAULT
    version.date_len = DRIVER_DATE.len();
    version.date.write_vm_slice(DRIVER_DATE.as_bytes())...
    version.desc_len = DRIVER_DESC.len();
    version.desc.write_vm_slice(DRIVER_DESC.as_bytes())...
    Ok(0)
}
```
**libdrm 的标准调用模式**（先传 NULL 拿长度，再分配缓冲拿数据）：
1. 第一次：`name=NULL, name_len=0` → 预期内核**只填长度**，不写数据；当前实现**无条件写** → `EFAULT`
2. 第二次：`name=buf, name_len=bufsize` → 预期按 `min(len, bufsize)` 写入；当前实现**不按用户缓冲长度截断**（有溢出风险）

### 1.2 具体步骤

| 步骤 | 动作 | 说明 / 命令 |
|---|---|---|
| **P0-S0** | 复现基线并记录 | 在冻结镜像上跑一轮诊断会话，抓取 `drmprobe v2` 的当前输出（`drmGetVersion -> NULL errno=14`），作为 before 证据 |
| **P0-S1** | 侦察 `UserPtr` API | 读 `posix/types/src/`（UserPtr 定义），确认空指针判断方式：`UserPtr::is_null()`，或 `as_ptr() == 0`。若两者皆无，按底层 usize 地址判 0 |
| **P0-S2** | 修改 `DrmVersion::handle` | 在 `card0.rs` 中：① 三个字符串字段先填长度；② **仅当指针非空且长度非 0 时才写入**，且写入长度取 `min(DRIVER_*_LEN, version.<field>_len)`。示例见 §1.6 |
| **P0-S3**（可选，推荐） | 顺带修 `DrmUnique::handle` | 同文件第 165–177 行是同一模式（`unique.unique.write_vm_slice` 无条件写），libdrm 的 `drmGetBusid` 会触发同样问题。一次修好 |
| **P0-S4** | 重编译内核 | `make build`（确认无警告/错误；`xkernel_aarch64-qemu.bin` 重新生成） |
| **P0-S5** | 验证 | 起会话 → `drmprobe v2` → 核对 §1.6 的判定项 |
| **P0-S6** | 回归测试 | `drmprobe v2` 的**带缓冲单次调用**仍需 `errno=0`；确认其余流程（weston/chromium/其他 uapp）不受影响 |
| **P0-S7** | 固化与上报 | `git add -p` 提交；写补丁说明；给上游（gitee openkylin/x-kernel）提 issue/PR；git tag 存 before/after 基线 |

### 1.3 涉及文件
| 文件 | 动作 | 说明 |
|---|---|---|
| `io/drmdevice/src/card0.rs` | **修改** | `DrmVersion::handle`（必选）+ `DrmUnique::handle`（推荐） |
| `posix/types/src/...`（UserPtr） | 阅读 | 确认空指针判断 API |
| `scripts/t490/drmprobe.c` | 复用 | 验证工具（已注入镜像） |

### 1.4 所需命令（速查）
```bash
# 编译/注入
cd ~/x-kernel && make build
# 起会话（复用冻结镜像，跳过装包）
scripts/t490/run_session_t490.sh p0-fix 600 45
# 读取验证结果（本地侧）
grep -E "drmGetVersion|VERDICT" ~/xk6/evidence/*/console.log | tail
```

### 1.5 风险与回退
| 风险 | 概率 | 缓解 / 回退 |
|---|---|---|
| 根因误判（EFAULT 并非 NULL 指针引起） | 低 | **先复现**：在 `drmprobe` 里加"NULL 指针直接调用"用例，确认复现 EFAULT 后再改；若不复现，转查其他调用方 |
| `UserPtr` 无 `is_null()` API | 中 | 按 `as_ptr() as usize == 0` 判断；仍失败则打印 `UserPtr` 内部布局再定 |
| 改动引入新错误（长度截断逻辑错） | 中 | 回归测试覆盖带缓冲调用；改动 ≤20 行、单文件，便于 review |
| 构建/启动失败 | 低 | 回退：`git checkout -- io/drmdevice/src/card0.rs`；旧 `kernel.bin` 与冻结镜像不受影响 |
| 上游不接受补丁（需以真实 libdrm 用法佐证） | 低 | 补丁说明中引用 libdrm `drmGetVersion` 的标准两次调用模式 + EFAULT 实测日志 |

### 1.6 验收标准（量化判定）

**代码改动（预期形态，最终以源码为准）**
```rust
version.name_len = DRIVER_NAME.len();
if !version.name.is_null() && version.name_len > 0 {
    let n = core::cmp::min(DRIVER_NAME.len(), version.name_len);
    version.name.write_vm_slice(&DRIVER_NAME.as_bytes()[..n])
        .map_err(|_| VfsError::BadAddress)?;
}
/* date / desc 同理 */
```

| # | 判定项 | 修复前（基线） | **通过标准** |
|---|---|---|---|
| A1 | `drmprobe v2`：`drmGetVersion(fd)` 返回值 | `NULL`（`errno=14`） | **非 NULL 指针** 且 `errno=0` |
| A2 | 二次调用模式（NULL 拿长度） | `EFAULT` | 第一次调用 `errno=0`（长度正确） |
| A3 | 读到的 driver name / version | —（读不到） | `simpledrm` / `1.0`（与内核 `DRIVER_NAME`/版本一致） |
| A4 | 回归：带缓冲单次调用 | `errno=0` | 仍 `errno=0` |
| A5 | 内核稳定性 | 无 panic | 会话 console.log 无 `panic`/`Backtrace`，其余 uapp 行为不变 |
| A6 | 改动规模 | — | 单文件、≤20 行、`make build` 零警告 |

---

## 2. P1 阶段：最小 sysfs 子集（打通 weston DRM backend）

### 2.1 根因（源码定位，已核实）
weston 14.0.2 `libweston/backend-drm/drm.c` 打开设备的**必经之路是 udev**：
```c
b->udev = udev_new();
if (config->specific_device)
    drm_device = open_specific_drm_device(...);
        └─ udev_device_new_from_subsystem_sysname(b->udev, "drm", name);   // 失败 → "could not open DRM device"
else
    drm_device = find_primary_gpu(b, seat_id);                              // 同样走 udev 枚举
```
**x-kernel 无 sysfs、无 udev** → libudev 查询必然失败。`libudev` 在**无 udev daemon** 时会
直接遍历/读取 sysfs（容器环境的通用 fallback），因此**只要提供正确的 sysfs 子集即可满足**。

### 2.2 架构设计
```
fs/filesystems/sysfs/                    ← 新增 crate（仿 devfs/procfs 的 SimpleFs+DirMapping 模式）
├── Cargo.toml
├── src/lib.rs        → 注册 FILE_SYSTEM_TYPE（kvfs::register_filesystem）
├── src/root.rs       → builder(fs)->DirMaker + nodes::class::add_root_entries
└── src/nodes/
    ├── mod.rs
    ├── class.rs      → 生成 /sys/class 及其子目录
    └── class_drm.rs  → 生成 /sys/class/drm/card0/{dev,device/uevent,vendor,device}
                                数据源：drmdevice 的 display 设备注册表（card0.rs 已有）

fs/boot/src/lib.rs      → mount_virtual_filesystems() 里加 /sys 挂载（仿 /proc 段）
顶层 Cargo.toml          → workspace 加 sysfs crate；fs/boot/Cargo.toml 加依赖
```
**文件内容**（card0，virtio-gpu）：
| 路径 | 内容 | 数据来源 |
|---|---|---|
| `/sys/class/drm/card0/dev` | `226:0` | DRM_MAJOR(226):minor(0) |
| `/sys/class/drm/card0/device/uevent` | `DRIVER=virtio_gpu`（实测为准） | `drivers/devices/virtio/src/gpu.rs` |
| `/sys/class/drm/card0/device/vendor` | `0x1af4` | virtio PCI vendor |
| `/sys/class/drm/card0/device/device` | `0x1050` | virtio-gpu PCI device |
| `/sys/class/drm/card0/device/{subsystem_vendor,subsystem_device}` | 视需要补充 | PCI 子系统 ID |
| `/sys/dev/char/226:0/`（可选） | 镜像上述 | libdrm 新版 API 路径 |

### 2.3 具体步骤

| 步骤 | 动作 | 说明 |
|---|---|---|
| **P1-S0** | 确认挂载机制 | 复核 `fs/boot/src/lib.rs:163+` 的 `mount_virtual_filesystems()`（已知仿 `/proc` 挂载） |
| **P1-S1** | 新建 `sysfs` crate 脚手架 | 仿 `devfs` 的 `Cargo.toml`/`lib.rs`/`root.rs`；先实现**空**的 `FILE_SYSTEM_TYPE` 并注册，确认内核能编译 |
| **P1-S2** | 实现 `/sys/class/drm/card0` 节点 | 在挂载时读取 `drmdevice` 的 display 设备注册表生成条目（**运行时动态**，非写死）；先只实现**只读静态内容**（dev/uevent/vendor/device） |
| **P1-S3** | 加挂载调用 | `fs/boot/src/lib.rs` 的 `mount_virtual_filesystems()` 仿 `/proc` 段加 `/sys` 挂载；**用 `#[cfg(feature = "xk6-sysfs")]` 或 Kconfig 开关控制，默认可关** |
| **P1-S4** | 验证 libdrm 层 | 重编译 → `drmprobe v2`：核对 `drmGetDevices2()` 与 `drmGetDeviceNameFromFd2()`（§2.6 B2/B3） |
| **P1-S5** | 验证 weston | 起会话：`libseat-shim`（seat 层）+ 真实 sysfs（udev 层）→ weston 应能发现设备并启动；看 `wayland-0` socket 与 screendump |
| **P1-S6** | 失败分支处理 | 若 libudev 仍失败（libdrm OK 但 weston 仍报 udev 错）→ 转入 **P1.5**：追加 uevent/netlink 最小实现，或临时用 libudev shim（P3 手段） |
| **P1-S7** | 固化与上报 | 提交、写补丁说明、提 issue/PR、git tag 存基线 |

### 2.4 涉及文件
| 文件 | 动作 |
|---|---|
| `fs/filesystems/sysfs/**`（新 crate） | **新建** |
| `fs/boot/src/lib.rs` | **修改**（加 `/sys` 挂载，受 feature 开关保护） |
| 顶层 `Cargo.toml`、`fs/boot/Cargo.toml` | **修改**（workspace 成员 + 依赖） |
| `fs/filesystems/devfs/src/{lib.rs,root.rs,nodes/dri.rs}` | 阅读（仿照模式） |
| `io/drmdevice/src/card0.rs`、`drivers/devices/virtio/src/gpu.rs` | 阅读（数据源：display 注册表、PCI ID、驱动名） |

### 2.5 所需命令（速查）
```bash
# 新增 crate 后
cd ~/x-kernel && make build
# 验证 libdrm 层
scripts/t490/run_session_t490.sh p1-sysfs 600 45
grep -E "drmGetDevices2|drmGetDeviceNameFromFd2|VERDICT" ~/xk6/evidence/*/console.log
# 验证 weston
grep -E "wayland-0|could not open DRM|no drm device|weston UP" ~/xk6/evidence/*/console.log
```

### 2.6 风险与回退
| 风险 | 概率 | 缓解 / 回退 |
|---|---|---|
| sysfs 实现量超预期（kclass 映射、多属性文件） | 中 | **先做只读静态子集**（card0 固定内容），跑通后再泛化；不追求通用 sysfs |
| libudev 仍不工作（需 netlink uevent/`/run/udev`） | 中高 | **分两步验证**：先 libdrm（drmGetDevices2 直接读 sysfs 应成功，门槛低），再 libudev；若 libudev 失败 → P1.5（uevent 最小实现）或 libudev shim |
| 挂载点冲突（`/sys` 已被占用/挂载） | 低 | 挂载前 `ensure_directory_path("/sys")` 会复用/创建；若与既有逻辑冲突，改挂到 `/sysfs` 并在 autorun 里 `mount --bind`（若支持） |
| 内核启动失败（新增 crate 引入 panic） | 中 | 挂载调用用 feature 开关默认关闭；`git checkout fs/boot/src/lib.rs` 回退挂载；`git stash` 全部改动 + 复用冻结镜像 |
| 设备内容写死（换 QEMU 设备后不准） | 低 | 挂载时从 `drmdevice` 注册表动态生成；登记 TODO：后续接 `subscribe_display_available` 做热更新 |

### 2.7 验收标准（量化判定）

| # | 判定项 | 修复前（基线） | **通过标准** |
|---|---|---|---|
| B1 | `cat /sys/class/drm/card0/dev` | 文件不存在 | 存在且内容为 `226:0` |
| B2 | `drmprobe v2`：`drmGetDevices2(0, buf, 8)` | `0 / errno=2` | **返回 1**（发现一个 DRM 设备） |
| B3 | `drmGetDeviceNameFromFd2(fd)` | `NULL` | **非 NULL**（如 `/dev/dri/card0`） |
| B4 | weston 启动后 10s 内 `wayland-0` socket | 不存在 | **存在**（`[ -S /run/user/0/wayland-0 ]`） |
| B5 | weston.log 关键错误 | 含 `could not open DRM device`/`no drm device found` | **不含**这两条 |
| B6 | QEMU monitor screendump 画面 | `Display output is not active.` | **非该黑屏**（出现 Weston 壁纸/光标/终端任一） |
| B7 | weston 进程稳定性 | 无法启动 | 存活 ≥60s（可复测长稳 ≥10 分钟） |
| B8 | 降级记录 | — | 若 libdrm 枚举成功但 udev/weston 仍失败 → 判"部分达成"，转入 P1.5 |

> **阶段完成定义**：P0 通过 A1–A6；P1 通过 B1–B7（B8 为降级记录项，不计失败）。

---

## 3. 里程碑与工作量预估

| 里程碑 | 内容 | 预估 |
|---|---|---|
| M0 | P0 修复 + 验证通过（A1–A6） | 0.5–1 小时 |
| M1 | sysfs crate 脚手架 + 挂载（能编译、空文件系统挂上） | 2–4 小时 |
| M2 | `/sys/class/drm/card0` 内容就绪 + libdrm 枚举通过（B1–B3） | 4–8 小时 |
| M3 | weston 直连成功（B4–B7） | +2–4 小时（含可能的 P1.5 调试） |
| M4 | 补丁整理 + 上游 issue/PR + 基线 tag | 1–2 小时 |

> 关键不确定项：**libudev 对 sysfs 的需求深度**（可能超出 libdrm 的最小集）。
> 应对：M2 用 `drmprobe v2` 快速验证 libdrm；M3 若卡在 udev 再补 uevent。

## 4. 附录：源码侦察记录（2026-09-21，已固化）

| 侦察点 | 结论 |
|---|---|
| `DrmVersion::handle` 缺陷 | `io/drmdevice/src/card0.rs:126-146`：无条件 `write_vm_slice` → NULL 指针 EFAULT |
| `DrmUnique::handle` 同类缺陷 | 同文件 165-177 行（`drmGetBusid` 受影响） |
| 挂载流程位置 | `fs/boot/src/lib.rs`：`prepare_namespace()`（104 行起）+ `mount_virtual_filesystems()`（163 行起） |
| devfs/procfs 挂载范式 | `mount_at("/dev"|"/proc", &FILE_SYSTEM_TYPE, ...)` + `ensure_directory_path` |
| **tmpfs 实情** | **x-kernel 有 tmpfs**（`memfs::TMPFS_TYPE`，挂在 `/dev/shm` 与 `/tmp`）——更正先前"无 tmpfs"的记录 |
| weston 的 udev 依赖 | `drm.c:3707 open_specific_drm_device()` 与 `find_primary_gpu()` 均强制 `udev_device_*` |
| libudev 无 daemon 时的行为 | 直接遍历/读取 sysfs（容器环境通用 fallback）→ 提供正确 sysfs 子集即可满足 |
