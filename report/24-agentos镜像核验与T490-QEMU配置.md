# agentos 镜像核验与 T490 QEMU 配置（2026-09-22）

## 结论先行

`agentos-disk.img.xz` 是一个可作为 x-kernel guest rootfs 使用的 2 GiB raw ext4 镜像，内容为 Alpine Linux 3.22。镜像内已经有实体 Chromium、Xorg/JWM、Mesa、libinput 和 `virtio` 场景需要的用户态基础，但没有 Weston、seatd 或 x-kernel 的 `xk-weston-start`。因此：

- 它满足“可以走 X11 启动 Chromium”的用户态前置条件，但不能直接宣称已经满足赛题的图形验收；必须在 x-kernel AArch64 QEMU 中实跑 Xorg/Chromium，并取得 QEMU monitor `screendump` 证据。
- 若选择赛题手册中的 Weston/Wayland 路线，仍需在镜像内安装 Weston 及其依赖，或改用已有 X11 kiosk 路线。
- 该镜像不是当前 T490 上的旧 4 GiB 实验镜像；替换后应将它保存为 `images/agentos-disk.img`，并在使用旧 Weston 专用轮次脚本时显式传 `BASE_IMG`，避免混用两种启动模型。

## 依据与只读核验

赛题 PDF 的要求与用户本次固定参数是两类信息，不能混为一谈：

| 来源 | 本次采用的约束 |
|---|---|
| 赛题六 PDF 第七节 | AArch64 QEMU；QEMU ≥ 8.0；评分数据纯 TCG；设备组合含 `virtio-gpu-pci`、`virtio-input`、`virtio-blk`、`virtio-net`；截图使用 QEMU monitor `screendump`。 |
| 用户本次请求 | vCPU 保持默认 4 核；内存固定 2G；不通过 `-nodefaults` 或过滤参数限制图形、输入、块、网络等设备；后续基于主办方镜像。 |

对 `agentos-disk.img.xz` 的只读检查结果：

- xz 元数据：压缩约 304 MiB，解压后 **2,048 MiB**。
- ext4 superblock：block size 4096，block count 524288，约 1.0 GiB 空闲块；镜像有足够空间继续安装图形组件。
- `/etc/os-release`：Alpine Linux v3.22.0。
- `/etc/apk/repositories`：同时启用 `v3.22/main` 与 `v3.22/community`（清华镜像）。
- `/etc/apk/world`：已安装 `chromium`、`xorg-server`、`jwm`、`mesa`、`mesa-dri-gallium`、`mesa-egl`、`xf86-input-libinput`、`xauth`、字体包等。
- `/usr/lib/chromium/chromium`：实体 AArch64 ELF，约 233 MiB；`/usr/bin/chromium` 是启动包装器。
- `/etc/inittab` 和 `/usr/local/bin/x11-session`：配置为 Xorg → JWM → Chromium kiosk，会话绑定 `tty1`，Chromium 使用 `--ozone-platform=x11`、ANGLE/OpenGL、禁用 Vulkan。
- 缺失项：`/usr/bin/weston`、`seatd`、`/usr/local/bin/xk-weston-start`、`/etc/profile.d/99-autostart.sh` 均不存在。

本地压缩文件 SHA-256：

```text
3B0C524AE600CDE79C7B2639D650593D46AE16F48A0419C923E4FBBFC3B2440A  agentos-disk.img.xz
```

这次检查没有在 Windows 上启动 QEMU；Windows/当前环境没有可用于赛题取证的 AArch64 QEMU，因此上述“符合”是镜像结构和用户态内容结论，不是图形运行通过结论。

## 已调整的 T490 单一配置源

已修改 [`scripts/t490/platform.env`](../scripts/t490/platform.env)：

```sh
PLAT_GRAPHIC="y"
PLAT_ACCEL="n"
PLAT_MEM="2g"
PLAT_SMP="4"
PLAT_VSOCK="n"
PLAT_INPUT_DEVICES="virtio-keyboard-pci virtio-mouse-pci"
PLAT_MAKE_ARGS="GRAPHIC=$PLAT_GRAPHIC ACCEL=$PLAT_ACCEL MEM=$PLAT_MEM SMP=$PLAT_SMP VSOCK=$PLAT_VSOCK"
```

`PLAT_VSOCK=n` 不是对 GPU、输入、块或网络设备的限制；它是 T490 的启动兼容设置，因为此前主机没有 `/dev/vhost-vsock`，开启 `vhost-vsock-pci` 会在 QEMU 初始化阶段直接失败。配置没有使用 `-nodefaults`、设备白名单或设备过滤；`virtio-rng` 仍由 xkmake 默认提供。

替换后建议将主办方镜像留档为：

```text
$HOME/x-kernel/images/agentos-disk.img
```

`t490_round.sh` 的默认值仍是旧 Weston 专用镜像，因为该脚本会注入 `/root/autorun.sh` 并依赖旧镜像的 `/etc/profile.d/99-autostart.sh`；使用 agentos X11 镜像时不要直接套用旧轮次脚本，先按 X11 会话路径单独验证。

## T490 替换镜像步骤

本次尝试从当前 Windows 会话直连 T490 时，`ssh mo@10.249.63.140` 返回 `Permission denied (publickey,password)`，备用地址 `10.157.181.239` 超时，所以**尚未实际写入 T490**。完成 SSH 认证后按以下顺序执行，先停 QEMU，再备份，再替换：

```powershell
# Windows：在仓库目录执行，避免 scp 处理中文绝对路径时出错
Set-Location 'E:\02_competition\中电杯'
scp .\agentos-disk.img.xz mo@10.249.63.140:/tmp/agentos-disk.img.xz
```

```bash
# T490：确认 QEMU 已停止；旧镜像先留档
set -eu
cd "$HOME/x-kernel"
pkill -TERM -f qemu-system-aarch64 2>/dev/null || true
sleep 5
pkill -KILL -f qemu-system-aarch64 2>/dev/null || true
mkdir -p images
cp -a disk.img "images/pre-agentos-$(date +%Y%m%d-%H%M%S).img"

# 解压并校验新镜像；不要直接覆盖压缩包
xz -dc /tmp/agentos-disk.img.xz > /tmp/agentos-disk.img
test "$(stat -c %s /tmp/agentos-disk.img)" -eq 2147483648
sha256sum /tmp/agentos-disk.img
cp -f /tmp/agentos-disk.img disk.img
e2fsck -f -y disk.img
cp -f disk.img images/agentos-disk.img
sha256sum disk.img images/agentos-disk.img
```

替换后先用短时 dry-run/启动冒烟，再进入长稳测试。由于新镜像默认走 X11，不能沿用旧镜像中“必有 Weston 日志”的断言；应先确认串口日志中的 `Xorg`、`jwm`、`chromium`，再用 monitor `screendump` 检查画面。

## 完整 QEMU 启动参数（T490 固定版本）

下面是对应 `GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`、加入虚拟键鼠后的完整命令。`<kernel.bin>` 应替换为 T490 当前构建产物的绝对路径；磁盘路径固定为替换后的 `disk.img`。

```bash
qemu-system-aarch64 \
  -m 2g \
  -smp 4 \
  -cpu cortex-a76 \
  -machine virt,gic-version=3 \
  -kernel /home/mo/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file=/home/mo/x-kernel/disk.img \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::61005-:5555,hostfwd=udp::61005-:5555 \
  -device virtio-gpu-pci \
  -vga none \
  -serial mon:stdio \
  -object rng-random,id=host_rng0 \
  -device virtio-rng-pci,rng=host_rng0 \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci
```

对应仓库入口（推荐，不手写整条命令）：

```bash
cd "$HOME/xk6"
bash scripts/t490/run_session_t490.sh agentos-x11 600 60
```

该入口会从 `platform.env` 读取 2G/4核/纯 TCG/图形/输入配置，并把完整实际命令写入证据目录的 `cmd.txt`；平台预检应确认命令行含 `-m 2g`、`-smp 4`、`virtio-gpu-pci`、`virtio-keyboard-pci`、`virtio-mouse-pci`、`virtio-blk-pci`、`virtio-net-pci`，且不含任何 `-accel` 或 `-nographic`。

如果将来 T490 主机补齐 `/dev/vhost-vsock`，才可把 `PLAT_VSOCK` 改回 `y`；那会额外出现 `-device vhost-vsock-pci,id=virtiosocket0,guest-cid=103`，不属于本次浏览器运行的必需设备。
