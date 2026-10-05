# 阶段 0 冻结报告 · 2026-09-22（T490）

> 对应执行计划《下一步执行计划：在无 shim 的 x-kernel 图形链路中显示并验证官方 HTML 三页》
> 的阶段 0「冻结真实现场，修正实验基础设施」。
> 本目录即为该阶段的证据包；全部结论都是**只读核查 + 可复现命令**的产物。

---

## 0. 结论速览

| 步骤 | 状态 | 关键结论 |
|---|---|---|
| 0.1 保存状态 | ✅ | HEAD `c2eabd5`；2 文件未提交修改（**错误扩展**）；内核 `6ab03917`；无 QEMU 残留 |
| 0.2 校验官方页面 | ✅ | 官方包 / 远端 / guest 镜像内**三处逐字节一致**，无行尾转换 |
| 0.3 修复会话守卫 | ✅ | 工具预检 + flock 互斥 + `/proc/<pid>/exe` 判定（已推送并预检） |
| 0.4 修复成功判据 | ✅ | 探针自证 + `[PROBE_EXIT]` + `GATE` 行 + `STRICT_GATE` 分层最终码 |
| 0.5 安全预检 | ✅ | 语法 / 编译 / 互斥锁正负样本 / 注入器正负样本 / 像素判据负对照 —— 6 项全通过 |
| ⭐ 额外 | ✅ | **阶段 1.1 的 ABI 对照基线提前完成**，并据此撤销「缺口 D」 |

**本轮最重要的发现**：`drm_mode_get_plane` 的标准 uapi 是 **32 字节**（无 `crtc_x/crtc_y/x/y`）。
既有的 `p3` 修改把内核改成了 48 字节 ⇒ **破坏了标准 libdrm 客户端**（独立真缺陷，须回退），
但**不是** Weston 失败的原因 —— weston6 在 p3 之前（正确 ABI）就报同样的
`Failed to find primary plane`。详见 `report/32`。

---

## 1. 现场快照（0.1）

| 项 | 值 |
|---|---|
| 主机 | T490 `mo@10.249.63.140`；load 0.00；无 QEMU 残留进程 |
| 源码 | `/home/mo/x-kernel`，HEAD `c2eabd524461c79631d7b737f4c8fa09bd24e96e` |
| 工作树 | `M io/drmdevice/src/card0.rs`、`M io/drmdevice/src/drm.rs`（+16 / −2） |
| 内核产物 | `target/xkmake/kplat-aarch64/release/kernel.bin` = `xkernel_aarch64-qemu.bin`，sha256 `6ab03917…` |
| 基础镜像 | `images/agentos-weston.img` sha256 `bb25e0b2…`（2 GiB） |
| 父镜像 | `images/agentos-disk.img` sha256 `cfb24123…` |
| 工作副本 | `disk.img` sha256 `e6b9641d…`（每轮由 BASE_IMG 覆盖） |
| 构建配置 | `auto.conf` / `autoconf.h` / `.config` 已快照（见 `src-snapshot/`） |
| 平台参数 | `GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`（`platform.env`，单一真源） |

**guest 关键包版本**（来源 `agentos-weston.img:/lib/apk/db/installed`，共 262 包）：

```
weston 14.0.2-r1      seatd 0.9.1-r0       libseat 0.9.1-r0     libdrm 2.4.124-r0
chromium 142.0.7444.59-r0                   mesa 25.1.9-r0       pixman 0.46.4-r0
libevdev 1.13.3-r0    libxkbcommon 1.8.1-r2 xkeyboard-config 2.43-r0
freetype 2.13.3-r0    fontconfig 2.15.0-r3  harfbuzz 11.2.1-r0
```

guest 库现场：`libdrm.so.2.124.0`、`libseat.so.1`（Sep 22 20:03 新装）、`libudev.so.1`、
`libinput.so.10.13.0`、`libevdev.so.2.3.0`；`/usr/bin/{weston,seatd,chromium}`；
`/usr/lib/weston/{kiosk-shell,desktop-shell,screen-share,libexec_weston}.so`。

## 2. ABI 基线（阶段 1.1，详见 `abi-baseline.txt`）

```
sizeof(drm_mode_get_plane) = 32
DRM_IOCTL_MODE_GETPLANE    = 0xC02064B6  (SIZE=32)

x-kernel iowr(HEAD 32B)   = 0xC02064B6   ← 一致 ✓
x-kernel iowr(当前 48B)    = 0xC03064B6   ← 不一致 ✗
```

- 工具：`scripts/t490/abi_probe.c`（宿主 `gcc` 运行 + aarch64 `musl-cross` 交叉编译）
- 两侧头文件 sha256 与 4 条 `_Static_assert` 均记录在案
- 机制：`iowr::<T>()` 把 `size_of::<T>()` 编进请求值；分派 `match cmd` 精确匹配 ⇒ 尺寸即契约

## 3. 官方三页核验（0.2，详见 `pages-verification.txt`）

| 页面 | sha256 | size | 官方包 vs 仓库 vs guest |
|---|---|---|---|
| `index.html` | `831cf28f…` | 5730 | **三处一致** |
| `interaction.html` | `58130daa…` | 10991 | **三处一致** |
| `layout.html` | `a1b04f9a…` | 11444 | **三处一致** |

`testpages.tar.xz` 自身 sha256 = `66afe539…`；**无 CRLF 转换**（历史"仅做过换行转换"的
猜测不成立，三页是原样副本）。

## 4. 脚本漂移对账（G0 要求）

归一化后对比（`scripts-drift.txt`）：MISMATCH **4** / 仅本地 **71** / 仅远端 **4**。

| 文件 | 方向判定 | 处理 |
|---|---|---|
| `round_assert.sh` | 远端更新（多回收 7 个 guest 日志） | **远端 → 本地**，已同步 |
| `ppm_assert.py` | 本地是超集（含 20 处 official 官方页判据；CLI 旗标兼容） | **本地 → 远端**，已推送 |
| `README.md` | 本地较新（19.6 KB vs 17.1 KB） | 保留本地为权威（待人工确认） |
| `autorun_v5.sh` | 本地较新（10.7 KB vs 6.9 KB） | 保留本地为权威（历史脚本） |
| 仅远端 4 个 | 全是备份文件（`.bak-logs` / `.pre-agentos-*`） | 不动 |
| 仅本地 71 个 | 多为历史轮次脚本（远端从未同步） | 不动，已记录 |

## 5. 本次改动清单（0.3 / 0.4）

| 文件 | 改动 | sha256（前 16） |
|---|---|---|
| `t490_round.sh` | 三层会话守卫（工具预检 / flock 互斥 / `/proc/exe` 判定）+ 轮末 `build-manifest.txt` 指纹归档 | `d7cbaf4a…` |
| `run_session_t490.sh` | `STRICT_GATE` 分层最终码（判据失败可让整轮失败） | `64afe6ab…` |
| `round_assert.sh` | 新增 ③.5 探针必验项（`[PROBE_EXIT]`/`[PLANESUM]`/`[PROBE_ABI]`）+ `GATE` 行 | `5eb0e19c…` |
| `drmplaneprobe.c` | 结构体回退标准 32B + 4 条 `_Static_assert` + 运行期 `[PROBE_ABI]` 自检 + 返回码折入 verdict + `[PROBE_EXIT]` | `bb7767d6…` |
| `abi_probe.c` | 新增（ABI 对照工具） | `1d3f5550…` |
| `ppm_assert.py` | 本地超集版本落地到远端（含官方页判据） | `597a3e0d…` |

> 全部改动已推送到 T490 `~/xk6/scripts/t490/`，推送后双侧 sha256 一致。

## 6. 预检结果（0.5，详见 `precheck-0.5.txt`）

| 项 | 结果 |
|---|---|
| 1. `bash -n` 四个脚本 | 全 OK |
| 2. `drmplaneprobe.c` 交叉编译 | OK（4 条静态断言通过），110 792 B static aarch64 |
| 3. flock 互斥锁正/负样本 | first 取得 ✓ / second 被拒 ✓ |
| 4. QEMU 探测循环自测 | `QEMU_FOUND=0`，**不匹配检查命令自身** |
| 5. 页面注入器正/负样本 | 正样本 rc=0（三页 `PAGE_VERIFY OK`）／负样本 rc=1 |
| 6. `ppm_assert.py` 负对照 | 对失效帧判 `严格集 0/5 通过`，rc=1 ✓ |

## 7. G0 逐项核对

| G0 要求 | 结果 |
|---|---|
| 基础镜像完整哈希 | ✅ `agentos-weston.img = bb25e0b2…`、父镜像 `cfb24123…`、内核 `6ab03917…` |
| 实际包版本 | ✅ guest apk 数据库导出（§1） |
| 页面来源 | ✅ 官方包 ↔ 仓库 ↔ guest 三处一致，含 hash |
| 远端与本地脚本差异 | ✅ 归一化对账完成，方向已判定并执行 |
| 「在线、空闲、干净」不当作事实 | ✅ 全部重新核实（含内核哈希实测、QEMU 进程实测） |

**放行判定：G0 通过**，可以进入阶段 1.2（用标准布局探针取得当前内核的 before 证据）。

## 8. 未闭环 / 风险（诚实列出）

1. **`README.md` / `autorun_v5.sh` 的漂移未处理** —— 需要人工确认哪一版是权威（本轮不影响执行）。
2. **仅本地 71 个文件从未同步到远端** —— 其中可能包含本轮要用的工具，取用前须核对（沿用既有纪律）。
3. **`drmstdprobe.c`（真实 libdrm 客户端探针）尚未编写** —— 阶段 1.2 的前置。
   需要确认 guest 的 `/lib/ld-musl-aarch64.so.1` 存在（动态链接前提）。
4. **`ppm_assert.py` 的本地超集版本此前从未在真实轮次里跑过** —— 本轮才首次落地到远端，
   其 official 判据的行为需在阶段 4/5 的首轮验证。
5. **Weston `Failed to find primary plane` 的真实根因仍未定位** —— 已知它**不是** GETPLANE ABI；
   阶段 3 的调试顺序（真实 GETPLANE → 属性元数据 → 格式与 CRTC 匹配 → dumb/ADDFB/SETCRTC）保持不变。
6. 历史证据（weston1–8）的 `guest/` 目录多为空（早期 `round_assert` 的日志回收清单不含 weston 日志）
   —— 这是**历史取证的既成缺口**，不可补；已通过 `build-manifest.txt` + 扩展回收清单防止复发。
