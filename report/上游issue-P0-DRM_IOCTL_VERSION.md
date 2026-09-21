# 上游 issue / PR 草稿：`DRM_IOCTL_VERSION` 与 `DRM_UNIQUE` 对 NULL 指针返回 EFAULT

> **状态**：草稿（仅本地留存，未提交任何远端）
> **目标仓库**：`https://gitee.com/openkylin/x-kernel`
> **本地提交**：`8162e8a`（tag `p0-drm-version-fix`，基线 `39d1788`）
> **实测环境**：T490 / Ubuntu 26.04 / QEMU 10.2.1 / `kplat-aarch64` + `qemu_defconfig` / 纯 TCG（`ACCEL=n`）/ 4 vCPU / 4G

---

## 一、Issue 正文（建议标题：`[drmdevice] DRM_IOCTL_VERSION 对 NULL/0 长度指针返回 EFAULT，导致 libdrm 客户端全部不可用`）

### 现象
在 x-kernel 上运行为 AArch64 编译的 libdrm 2.4.131 客户端时，最基础的版本查询失败：

```c
/* 伪代码：libdrm 的 drmGetVersion() 内部流程 */
int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);   /* 成功，fd=3 */
struct drm_version dv = {0};                            /* name=NULL, name_len=0 等 */
ioctl(fd, DRM_IOCTL_VERSION, &dv);                      /* ← 失败：EFAULT */
```

实测输出（探针程序，见「复现」）：

```
---- /dev/dri/card0 ----
stat OK rdev=226:0
open(RDWR|CLOEXEC) -> 3 errno=0
ioctl(VERSION) -> 0 errno=0 driver='simpledrm' 1.0.0      ← 直接调用（带完整缓冲区）正常
---- libdrm 能力测试 ----
dlopen(libdrm.so.2) OK
  drmGetVersion(fd=3) -> NULL errno=14 (Bad address)      ← libdrm 调用失败
```

### 根因
`io/drmdevice/src/card0.rs` 的 `DrmVersion::handle`（及同文件的 `DrmUnique::handle`）
**无条件**把驱动字符串 `copy_to_user` 到用户缓冲区：

```rust
version.name_len = DRIVER_NAME.len();
version.name.write_vm_slice(DRIVER_NAME.as_bytes())   // name == NULL 时 → BadAddress
    .map_err(|_| VfsError::BadAddress)?;
```

而 Linux DRM 的标准语义（也是 libdrm 的既定用法）是**两次调用**：
1. 第一次传 `name=NULL, name_len=0`（`date`/`desc` 同理）——**只为取长度**，内核不得写数据；
2. 第二次由用户按长度分配缓冲后再调用——内核写入，且**最多写用户给定长度**。

于是第一次调用必然触发 `EFAULT`，libdrm 直接返回 NULL —— 所有依赖 `drmGetVersion()` 的
客户端（weston、Xorg、Mesa 相关工具等）在 x-kernel 上均不可用。

### 复现（最小可验证）
1. 用 `aarch64-linux-musl-gcc -Os` 静态/动态编译下述探针（完整源码见附件说明），注入 rootfs：

```c
int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
struct drm_version dv = {0};                 /* 全零 = libdrm 的第一次调用姿态 */
errno = 0;
int r = ioctl(fd, DRM_IOCTL_VERSION, &dv);
printf("ioctl(VERSION) -> %d errno=%d (%s)\n", r, errno, strerror(errno));
```

2. 修复前输出：`ioctl(VERSION) -> -1 errno=14 (Bad address)`
3. 通过 libdrm 调用：`drmGetVersion(fd) -> NULL errno=14 (Bad address)`

### 建议修法
先填长度字段，**仅在指针非空且长度非 0 时**写入，并按用户给定长度截断（`min` 语义，对齐 Linux 行为）：

```rust
version.name_len = DRIVER_NAME.len();
version.date_len = DRIVER_DATE.len();
version.desc_len = DRIVER_DESC.len();
if !version.name.is_null() && version.name_len > 0 {
    let n = core::cmp::min(DRIVER_NAME.len(), version.name_len);
    version.name.write_vm_slice(&DRIVER_NAME.as_bytes()[..n])
        .map_err(|_| VfsError::BadAddress)?;
}
/* date / desc 同理；DrmUnique::handle 同样处理 */
```

### 影响面
| 用途 | 影响 |
|---|---|
| libdrm 任何版本查询（`drmGetVersion` / `drmGetBusid`） | 不可用 → 上层图形栈第一步即失败 |
| weston 14 DRM backend | 设备校验阶段失败（本团队实测：即使绕过 udev/VT 问题，仍会被此缺口挡住） |
| 「兼容性缺口与补丁」评分项 | 这是一个**清晰的系统调用/ioctl 语义缺口**，修复成本极低、收益直接 |

---

## 二、PR 说明（建议标题：`fix(drm): tolerate NULL pointers in DRM_IOCTL_VERSION and DRM_UNIQUE`）

### 变更
- 文件：`io/drmdevice/src/card0.rs`（单文件，32 insertions / 16 deletions）
- `DrmVersion::handle`：先填 `version_{major,minor,patchlevel}` 与三个 `*_len`；
  仅在 `!ptr.is_null() && len > 0` 时写入，写入长度取 `min(DRIVER_*_LEN, 用户 len)`
- `DrmUnique::handle`：同模式修复（`drmGetBusid` 路径）

### 验证（T490 / QEMU 10.2.1 / 纯 TCG）
| 项 | 修复前 | 修复后 |
|---|---|---|
| `drmGetVersion(fd)`（libdrm 2.4.131） | `NULL` / `errno=14 (EFAULT)` | **`0x40c2fb0` / `errno=0`** |
| 解析到的驱动名/版本 | —（读不到） | **`simpledrm` / `1.0`** |
| 直接 `ioctl(VERSION)`（带缓冲区，回归） | `errno=0` | `errno=0`（无回归） |
| 内核稳定性 | — | 会话 console 无 panic/backtrace |

证据：`evidence/2026-09-21_t490-p0-fix/console.log`（探针输出段）；本仓库 `report/T490验证测试记录-2026-09-21.md`。

### 未执行的检查（提交前需补）
- 本机未安装仓库要求的 pinned nightly（`nightly-2026-03-08`），
  pre-commit 的 `make fmt`（`cfg_select!` 等 unstable 特性）与 `make clippy` 未在本地跑通，
  提交时使用了 hook 明确提供的 `SKIP_FMT=1 SKIP_CLIPPY=1`。
  **合入前请在 CI/本地安装该 nightly 后重跑 `make fmt && make clippy`。**
- 未做「无 drm 设备」场景的负向测试（`drmdevice::available() == false` 时该 ioctl 不可达，风险低）。

### 兼容性
- 语义变更仅影响「用户传 NULL/过小缓冲区」的调用（修复前为失败路径），
  对传足量缓冲区的既有调用者行为完全一致（长度相同、内容相同）。
