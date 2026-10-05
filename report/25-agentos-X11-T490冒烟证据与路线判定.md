# agentos X11 镜像 · T490 替换、冒烟测试与路线判定

日期：2026-09-22

## 结论先行

1. `agentos-disk.img.xz` 已成功替换到 T490 的 `/home/mo/x-kernel/disk.img`。
2. 旧 4 GiB 镜像已备份为：
   `~/x-kernel/images/pre-agentos-20260922-164822.img`
3. 新镜像 ext4 检查通过，远端 SSH 正常，QEMU 能以 2 GiB / 4 vCPU / 纯 TCG 正常启动 x-kernel guest。
4. X11/Chromium 冒烟测试**未通过**：guest 能启动到 root shell，但图形输出一直未激活；QEMU monitor `screendump` 明确显示 `Display output is not active.`
5. 失败不是 Chromium 本身，也不是镜像缺少 X11 用户态组件。手动探针显示，当前主要阻塞是：
   - x-kernel 当前 PID 1 是 `/bin/sh --login`，不会执行 BusyBox `/etc/inittab`，所以 `tty1::respawn:/usr/local/bin/x11-session` 不会自动生效；
   - 手动运行 `x11-session` 后，在 Xorg 启动命令的输出重定向处报：
     `/usr/local/bin/x11-session: line 24: can't create /dev/ttyAMA0: Permission denied`；
   - 因此 Xorg 未建立 `/tmp/.X11-unix/X0`，JWM/Chromium 也没有启动。
6. **当前不建议立即补装 Weston/seatd。** 现有证据首先指向 x-kernel 的 init/串口设备语义与镜像启动脚本不匹配；先修复 X11 启动链的诊断价值最高。只有修复启动链后，Xorg 仍不能激活 DRM/KMS，或确定 x-kernel 的显示输出无法被 Xorg 接管时，才切换 Wayland 并安装 Weston/seatd。

## 1. 远端镜像替换

### 1.1 输入镜像

本地文件：`agentos-disk.img.xz`

- 大小：318,760,140 bytes
- SHA-256：
  `3b0c524ae600cde79c7b2639d650593d46ae16f48a0419c923e4fbbfc3b2440a`
- 解压后大小：2,147,483,648 bytes
- 解压后镜像 SHA-256：
  `441b4504cfa7fef53f8458f28b4a80eb71f4fd08104f9f260627993fce47fe84`

### 1.2 替换结果

| 项目 | 结果 |
|---|---|
| T490 | `mo-ThinkPad-T490` |
| SSH 用户 | `mo` |
| 生效地址 | `10.249.63.140` |
| 旧 `disk.img` | 4,294,967,296 bytes |
| 旧盘备份 | `~/x-kernel/images/pre-agentos-20260922-164822.img` |
| 新 `disk.img` | 2,147,483,648 bytes |
| 新 `images/agentos-disk.img` | 2,147,483,648 bytes |
| 新盘当前 SHA-256 | `cfb241235d6880a242464f98ac2707bdb9d6016f325ad47dbf97e55d726a6790` |
| `images/agentos-disk.img` SHA-256 | 与 `disk.img` 一致 |
| `e2fsck -fn` | 通过，无结构错误 |
| 替换后 SSH | 正常 |
| 测试结束后 QEMU | 无残留进程 |

注意：手动 X11 探针会在 guest 文件系统上创建 `/run/x11`、xauth 等运行时状态，因此替换后的 `disk.img` 与首次安装后保存的 `images/agentos-disk.img` 摘要可以不同；最终盘的 ext4 检查仍通过。旧盘备份保持不变。

## 2. 正式 X11/Chromium 冒烟轮次

证据目录：

`evidence/2026-09-22_t490-agentos-x11/2026-09-22_t490-agentos-x11/`

正式入口：

```bash
bash scripts/t490/run_session_t490.sh agentos-x11 600 60
```

实际 QEMU 关键参数：

```text
-m 2g
-smp 4
-cpu cortex-a76
-machine virt,gic-version=3
无 -accel
-device virtio-gpu-pci
-device virtio-keyboard-pci
-device virtio-mouse-pci
-device virtio-blk-pci
-device virtio-net-pci
-serial mon:stdio
```

### 2.1 平台环境证据

`platform-check.txt`：`PASS=36 FAIL=0 WARN=0`

`platform-compliance.txt`：`PASS=15 FAIL=0`，最终为 `PLATFORM_COMPLIANT`。

宿主指纹：

- Ubuntu 26.04 LTS
- Intel Core i7-8665U
- 宿主 x86_64，guest AArch64
- QEMU 10.2.1
- x-kernel commit `c2eabd524461c79631d7b737f4c8fa09bd24e96e`
- git describe：`v0.2-compat-p0p4-3-gc2eabd5`

### 2.2 运行与截图证据

- 实际运行时间：603.5 s
- `console.log`：存在 `SESSION END (exit=0)`，QEMU 正常收尾
- `timestamps.csv`：11 张截图，首张 45.1 s，末张 603.5 s
- PPM：11 张，均为 640×480、921,615 bytes
- 11 张 PPM SHA-256 全部相同：
  `11b8d01bb05554039a8f9d5b5911f5250d5fc5e686fa447cd43370c4c3c37757`
- `ppm-summary.txt`：
  - 严格集通过：0/11
  - 尺寸不符：0
  - 相邻帧心跳：0/10
  - renderer/JS 未被证明执行
- 将最终截图转为 PNG 后，画面文字为：

```text
Display output is not active.
```

这不是 Chromium 空白页面，而是 QEMU 显示后端报告没有 active display output。

## 3. 手动 X11 定位探针

诊断证据目录：

`evidence/2026-09-22_t490-agentos-x11-manual/`

该轮复用已经构建好的 `kernel.bin`，不重新编译 x-kernel，仅用于定位，不作为正式评分证据。

guest 内观测：

```text
Linux kylin-x 10.0.0 ... aarch64 Linux
```

镜像确实包含：

- `/usr/bin/Xorg`
- `/usr/bin/xauth`
- `/usr/bin/chromium`
- `/usr/lib/chromium/chromium`（实体 ELF）
- `/usr/bin/jwm`
- `/dev/dri/card0`
- `/dev/input/event0` 与 `/dev/input/mice`

`/etc/inittab`：

```text
::sysinit:/etc/init.d/kiosk-boot
tty1::respawn:/usr/local/bin/x11-session
ttyAMA0::respawn:/sbin/getty -L 115200 ttyAMA0 vt100
```

但 x-kernel guest 启动后直接显示：

```text
HOME=/root
PWD=/
kylin-x:~#
```

并没有执行 BusyBox init；因此 `/etc/inittab` 中的 `kiosk-boot` 和 `x11-session` 不会自动执行。

手动执行：

```sh
/usr/local/bin/x11-session >/root/x11-session-manual.log 2>&1 &
```

结果：

```text
xauth:  file /run/x11/auth does not exist
/usr/local/bin/x11-session: line 24: can't create /dev/ttyAMA0: Permission denied
ls: /tmp/.X11-unix: No such file or directory
```

对应脚本第 24 行：

```sh
Xorg :0 vt1 -nolisten tcp -auth "$XAUTH" >"$LOG" 2>&1 &
```

其中 `LOG=/dev/ttyAMA0`。由于 x-kernel 对 `/dev/ttyAMA0` 的打开权限/设备语义与 Alpine 镜像预期不一致，Xorg 在启动前就被 shell 重定向阻断。

## 4. 另一次无效诊断轮次

`evidence/2026-09-22_t490-agentos-x11-probe2/` 不作为结论依据。

原因：该轮入口重新触发 x-kernel 编译，远端 Rust 工具链对 `cfg_select` 不支持，失败于：

```text
error[E0658]: use of unstable library feature `cfg_select`
make: *** [Makefile:172: run] Error 101
```

它没有启动 QEMU，也没有产生图形证据。该问题属于远端构建环境偏差，不是本次 X11 路线判定。

## 5. 路线建议

### 当前建议：暂不切 Weston，先修 X11 启动链

优先级：

1. **修复启动模型**：让 x-kernel guest 执行镜像的 `/etc/init.d/kiosk-boot` 与 `/etc/inittab`，或新增明确的 x-kernel 兼容启动入口，不能假设 PID 1 是 BusyBox init。
2. **修正 `/usr/local/bin/x11-session` 的日志目标**：不要把 Xorg stderr 直接重定向到 `/dev/ttyAMA0`；改写到 `/root/xorg.log` 或 `/var/log/Xorg.0.log`，再由串口 shell 主动输出摘要。该改动属于用户态诊断/兼容性修复，不能冒充内核优化收益。
3. 再做一轮短测：确认 `/tmp/.X11-unix/X0`、Xorg、JWM、Chromium 进程和 `screendump` 是否出现真实画面。
4. 若 Xorg 能启动但仍报告 DRM/KMS 不可用，再单独检查 x-kernel 的 DRM master、VT、fbdev/virtio-gpu modeset 语义。

### 何时切 Weston/Wayland

满足以下任一条件后再切换：

- Xorg 日志明确显示无法打开 `/dev/dri/card0` 或无法完成 modeset，而不是脚本重定向/启动入口失败；
- 修正 init 和 Xorg 日志路径后，Xorg 仍不能创建 active display；
- 需要采用当前项目已验证的 Wayland + 软件 GL 路线，并接受给镜像增加 Weston、seatd 及其依赖。

补装 Weston/seatd 目前不能直接解决 `/etc/inittab` 不执行或 `/dev/ttyAMA0` 重定向失败，因此现在立刻安装属于绕过已定位问题，优先级较低。

## 6. 本次产生或修改的本地文件

- `scripts/run-session.py`：修正平台内存断言，接受当前平台配置的 `-m 2g`，并兼容历史归档的 `-m 4g`。
- `tmp/replace-agentos-on-t490.sh`：远端镜像替换脚本。
- `tmp/run-agentos-x11-probe.sh`：X11 诊断脚本。
- `tmp/run-agentos-x11-manual.sh`：复用已构建内核的手动 X11 探针脚本。
- `evidence/2026-09-22_t490-agentos-x11/`：正式 600 秒 X11 冒烟证据。
- `evidence/2026-09-22_t490-agentos-x11-manual/`：手动 X11 定位证据。

正式轮次证据结论：平台合规通过、QEMU 稳定运行通过，但图形/Chromium 功能验收失败；当前路线建议是先修 x-kernel 与 X11 镜像启动链，再决定是否切 Wayland。
