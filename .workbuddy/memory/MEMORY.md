# 项目长期记忆 · 中电杯（赛题六 · x-kernel Chromium 运行环境）

> **索引型**：细节看 `report/01–15`，流程看 `scripts/t490/README.md`。

## 1. 硬约束
- 赛题六（麒麟软件）；杭电 3 人；**决赛 2026-12-03 南邮**（报送 10-30、材料 11-20）
- 平台 **AArch64 QEMU**（`kplat-aarch64` + 组委会 `qemu_defconfig`），qemu ≥ 8.0；**初赛纯 TCG，禁 KVM/HVF**；
  四类设备 virtio-gpu-pci / virtio-input / virtio-blk / virtio-net
- 功能证据**只认 monitor `screendump`**；性能 ≥5 次中位数+波动范围+宿主指纹；before/after 基线**必须 git tag**
- 初赛 100 分：图形20 浏览器20 补丁25 性能15 文档10 演示10 —— **达标即满分、缺证据计 0**
- 分工：A 内核/驱动 ｜ B 用户态/图形 ｜ C 度量/工程。**别三人都扑 Chromium**

## 2. QEMU 平台参数单一真源（report/15）
- `scripts/t490/platform.env` = 第七节(一)1/2/3+(二) 取值 + 第八节 5 条链接；**改参数只改这里**
- `scripts/t490/t490_platform_check.sh` = 35 项合规预检 → `platform-check.txt`（RC=0 才合规）
- `scripts/run-session.py` 再对**实跑命令行**做 15 项断言 → `platform-compliance.txt`；证据目录共 8 文件
- 纯 TCG 判据：命令行**无任何 `-accel`** + `-cpu cortex-a76`；裸 `make run` 不合规（`-nographic`/无 gpu/`-m 1g`）

## 3. 构建 / 运行（T490）
完整命令见 `scripts/t490/README.md` §0/§2。必须记住的 4 条：
1. `export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"`
   （否则 `rustc` 落到 `/usr/bin` 的 1.93.1，而 `rust-toolchain.toml` 要 **1.95.0**）
2. `cp platforms/kplat-aarch64/qemu_defconfig .config && make defconfig`（**别照抄上游 README，路径 404**）
3. 装 chromium 前必须 `truncate -s 4G disk.img && e2fsck -f -y disk.img && resize2fs disk.img`（关机态；否则 ENOSPC）
4. `make run` **永不挂 virtio-input**（`qemu.rs` input 计数=0）→ 靠 `--with-input`；
   取证 `-serial mon:stdio` → `Ctrl-A c` → `screendump x.ppm` → `scripts/ppm2png.py`

## 4. 已修缺陷（report/09–13）
P0 `card0.rs` `DRM_IOCTL_VERSION` NULL→EFAULT（`8162e8a`/tag `p0-drm-version-fix`）｜P1 AF_UNIX STREAM 缺 SCM_RIGHTS｜
P2a `sched.rs::scheduler_target()` 只按 tgid 查｜P2b netlink `bind()` groups≠0→EOPNOTSUPP｜
P3 `ctl.rs` `PR_SET_NO_NEW_PRIVS` 无条件 ENOSYS｜P4 `madvise` 白名单过窄+VMA 须连续覆盖。
应用器 `scripts/t490/p{1,2,3,4}_*.py`（幂等）

## 5. 当前阻塞（report/13）
renderer 从未创建；GPU 子进程 exec 后 10–13 s 静默退 **191**（无未实现 syscall、无 panic/OOM）。
已排除 fork/execve/SO_PEERCRED/memfd/SEQPACKET/eventfd/timerfd/epoll/signalfd。
**下一步 G17**：`sendmsg(SEQPACKET)` 带 `SCM_CREDENTIALS` → EINVAL(22)（crashpad `missing credentials` 根因）。

## 6. 待办
G6 鼠标无 evdev（`input.rs::physical_location()` 硬编码 `virtio0/input0`+`inputdev/lib.rs` 按 id 去重 → 第二台被丢弃）｜G13 landlock｜G16 `PR_SET_PDEATHSIG` EINVAL（刻意不修）｜**R1 采数前先 commit+tag**（dirty 违反七(二)3）｜R3 缺中位数聚合脚本

## 7. 环境陷阱（T490 = `mo@10.249.63.140`，备用 `10.157.181.239`）
- 连不上**先 ping 两个 IP**；Windows ssh 远端命令用单引号
- 本机 bash 缺 coreutils → `export PATH="/c/Users/12697/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:$PATH"`
- 冻结镜像 `~/x-kernel/images/pkg-installed.img`（`56302b8f…`）= `BASE_IMG`；旧"apk 预装"镜像是 **0 字节空壳**
- **别用 `pkill -f <pat>`**（会自杀）→ `pkill -f "qemu-syste[m]"`；guest 日志写 `/root/`（`/tmp` 是 tmpfs）
- weston 必须显式 `--socket=wayland-0`、`--drm-device=card0`（简写）
- guest 网络不可达 → 宿主 `apk.static --usermode --arch aarch64 --root DIR` 预装；**别用 `apk search` 判存在**
- Windows `scp` 不处理含中文绝对路径 → 先 `cd` 再用相对路径

## 8. 上游协作
失效 docs 5 文件 17 行（`platforms/<arch>-qemu-virt/defconfig` 404）已在 fork `mofan0810/x-kernel`
分支 `fix-doc-defconfig-path`（`0a0f2a2`）修好，**上游未提**；检索 `grep -rn "qemu-virt" README.md docs/`，
`xtask/xconfig/tests/fixtures/.../Kconfig:29` 是夹具**不可改**。PR 格式 `!<MR号> <type>(<scope>): <subject>`，
AI review 有 Description 维度 → 正文必写 what/why/expected。详见 report/14 §1.1。

## 9. 目录
```
中电杯/ docs/ 赛题材料  tmp/ 过程产物  scripts/ 观测脚本  evidence/ 证据仓库  report/ 技术报告
```
