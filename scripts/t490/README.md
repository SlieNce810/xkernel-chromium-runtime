# `scripts/t490/` 脚本索引与复现指南

> 目标机：**T490 裸金属**（ThinkPad T490 · Ubuntu 26.04 LTS · i7-8665U 4C8T · 14G）
> 连接：`mo@10.249.63.140`（IP 会变：`10.157.181.239` / `10.249.63.140` 交替，连不上先 ping 两个）
> 执行通道：本机 Windows **原生 OpenSSH**（`ssh`/`scp`）直连；**不再依赖 WSL**
> ⚠️ Windows 的 `scp` **不处理含中文的绝对本地路径**（`/e/…/中电杯/…` 会被转义报 No such file）
> → **先 `cd` 进目标目录再用相对路径**。
> 代码目录：T490 `~/x-kernel`（clone 自 `https://gitee.com/openkylin/x-kernel.git`）
> 工作目录：T490 `~/xk6/{scripts,evidence,tmp}`
> 非交互 ssh 下必须显式
> `export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"`
> （否则 `rustc` 落到 `/usr/bin/rustc` 1.93.1，而 `rust-toolchain.toml` 要 1.95.0）

---

## 0. 平台合规基线（《赛题六》PDF 第七节逐条落地）

> **QEMU 平台参数只有一处真源**：`scripts/t490/platform.env`
> **机器可校验的合规预检**：`scripts/t490/t490_platform_check.sh`
>
> 改参数**只改 `platform.env`** —— 不要再在任何脚本/文档里手写 `GRAPHIC=… ACCEL=… MEM=…`。
> 此前这些值散落在 4 个地方，改一处忘一处就会与赛题要求漂移（见 `report/15`）。

### 0.1 条款 → 落点 → 断言 追溯矩阵

| 赛题条款 | 原文要点 | 本仓库落点 | 机器断言（预检项） |
|---|---|---|---|
| **七(一)1** | AArch64 QEMU 虚拟平台（x-kernel `kplat-aarch64` + 组委会 `qemu_defconfig`），不接受其他架构 | `platform.env` 的 `PLAT_ARCH/PLAT_HAL/PLAT_DEFCONFIG`；`build_xk_t490.sh` §1/§1b | `ARCH="aarch64"`、`MACHINE_AARCH64_QEMU=y`、无 `ARCH_{RISCV64,X86_64,LOONGARCH64}=y`、无 `RK3588`、无 `KFEAT_VMM`；**线上 `.config` 与基线重展开逐字节一致** |
| **七(一)2** | `qemu-system-aarch64` ≥ 8.0；评分数据必须出自**纯 TCG**，初赛禁用 KVM/HVF | `PLAT_QEMU_MIN_MAJOR / PLAT_ACCEL / PLAT_CPU_TCG` | QEMU 版本 ≥ 8.0；命令行**无任何 `-accel`**；含 `-cpu cortex-a76`（非 `host`） |
| **七(一)3** | 设备组合 `virtio-gpu-pci` + `virtio-input` + `virtio-blk` + `virtio-net`；功能证据统一用 monitor `screendump` | `PLAT_GRAPHIC / PLAT_INPUT_DEVICES / PLAT_REQUIRED_DEVICES` | 五类设备字面均出现；含 `-device virtio-gpu-pci`、`-vga none`、`-serial mon:stdio`；**不含 `-nographic`** |
| **七(一)3** | 以组委会发布基线为准 | `PLAT_VSOCK=n`（关掉基线外多余的 `vhost-vsock-pci`） | 设备清单里不出现 `vhost-vsock-pci` |
| **七(二)1/3** | before/after 基线 = 队伍首个可运行版本（**git tag 存档**），组委会复核存档代码 | `run-session.py::host_fingerprint(cwd)` | `env.txt` 的 `git_commit` / `git_describe` **非空**；`-dirty` 时预检给 WARN |
| **七(二)4** | 每项指标 ≥5 次取中位数 + 波动范围；注明宿主 CPU 型号/内存/QEMU 版本/OS | `PLAT_REPEAT_MIN / PLAT_STAT`；`run-session.py` 的 `env.txt` | `env.txt` 含 `cpu_model / mem_total / os_pretty / qemu-system-aarch64 / machine / host_vs_guest` |
| 第六节(一) | 浏览器基础功能要「提供**完整运行命令**」 | `run-session.py::write_cmd_txt()` | `cmd.txt` 含字面 `qemu-system-aarch64 …` 行（xkmake 干跑抓取），且 `grep -c -- '-accel'` = 0 |

### 0.2 用法

```bash
# 独立跑平台预检（只读；唯一"副作用"是在 /tmp 重展开一次基线 + 一次 xkmake dry-run）
bash ~/xk6/scripts/t490/t490_platform_check.sh ~/xk6/tmp/platform-check.txt
echo $?      # 0 = PLATFORM_COMPLIANT；1 = 有 FAIL

# 会话脚本已自动串联：预检 → run-session.py（后者再对**实跑命令行**断言一次）
bash ~/xk6/scripts/t490/run_session_t490.sh <tag> <duration> <interval>
# 预检 FAIL 会阻断；确需带病起会话：PLAT_ALLOW_NONCOMPLIANT=1 bash …

# run-session.py 单独用时，加 --require-platform-compliance 可让不达标直接拒跑（退出码 4）
python3 scripts/run-session.py --cwd ~/x-kernel --make-args "$PLAT_MAKE_ARGS" \
    --with-input --require-platform-compliance --duration 600 --out evidence/demo
```

证据目录里因此多了两个自证文件：

| 文件 | 内容 |
|---|---|
| `platform-check.txt` | 35 项平台合规预检（`.config` / QEMU 版本 / 设备组合 / git tag / 宿主指纹） |
| `platform-compliance.txt` | 对**实跑** QEMU 命令行的 15 项断言（纯 TCG、四类设备、取证通路） |

### 0.3 注意事项（改前必读）

1. **`-cpu cortex-a76` 本身就是纯 TCG 证据**：`qemu.rs:149` 里 `host` 只在 `accel.is_some()` 时出现。
   判据是「命令行**无 `-accel`**」，**不是**「命令行含 `--no-accel`」（那是 xkmake 层参数，不会出现在 QEMU 命令行里）。
2. **`make run` 裸调用不合规**：`GRAPHIC ?= n` → `-nographic`、无 `virtio-gpu-pci`、无 `-serial mon:stdio`；
   `MEM ?=` 为空 → xkmake 默认 `-m 1g`。必须显式传 `GRAPHIC=y ACCEL=n MEM=4g SMP=4`。
3. **`virtio-input` 工具链永不添加**（`qemu.rs` 全文件 input 关键字计数 = 0），只能靠 `QEMU_ARGS`
   或 `run-session.py --with-input` 补。
4. **`.config` 被 `.gitignore:46` 忽略** → 架构错误在 git 层面不可见，必须靠 §1b 的显式断言。
   上游 README 教的 `cp platforms/aarch64-qemu-virt/defconfig .config` **已失效（实测 404）**。
5. **`platform-check.txt` / `platform-compliance.txt` 是采数前置**：`[FAIL]` 存在时该轮数据不得作为评分证据。

### 0.4 第八节 参考资料（方案选型的权威出处）

| # | 资料 | 链接 | 在本方案中的用途 |
|---|---|---|---|
| 1 | x-kernel 内核基线 | https://gitee.com/openkylin/x-kernel | 补丁落点与构建链（P0–P4、`platforms/kplat-aarch64/qemu_defconfig`） |
| 2 | Wayland 协议 | https://wayland.freedesktop.org/ | 主路线：Weston compositor + `--ozone-platform=wayland`，wayland fd 传递（P1 SCM_RIGHTS） |
| 3 | X.Org / X11 参考 | https://www.x.org/wiki/ | 兜底路线：Weston `--xwayland` → x11 |
| 4 | X.Org 官方文档 | https://xorg.freedesktop.org/archive/current/doc/ | X11 兜底路线的协议细节 |
| 5 | Chromium Ozone 平台 | https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md | Chromium 平台抽象层选型（wayland vs x11 vs headless） |

（同表亦内联在 `platform.env` 的 `PLAT_REF_*` 变量里，供脚本与文档共用。）

---

## 0b. 一页速览：单轮迭代怎么做

```bash
# ① 改内核（示例：P0 补丁）
scp scripts/t490/modify_card0.py  mo@T490:/tmp/
ssh mo@T490 'cd ~/x-kernel && python3 /tmp/modify_card0.py io/drmdevice/src/card0.rs && make build'
# ② 注入 guest 侧脚本/探针（如需）
scp scripts/t490/drmprobe.c mo@T490:~/xk6/scripts/t490/ && bash scripts/t490/t490_v15.sh   # 脚本内含编译+注入+起会话
# ③ 起会话（宿主侧编排：screendump + 全量日志）
ssh mo@T490 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh <tag> 900 45'
# ④ 读结果（本地）
ssh mo@T490 'grep -E "VERDICT|drmGet|Output |ERROR" ~/xk6/evidence/*/console.log | tail -40'
```

## 1. 目录分组

| 分组 | 文件 | 用途 |
|---|---|---|
| **platform** | `platform.env` | **★ 平台参数单一真源**：赛题第七节(一)1/2/3 的全部取值 + 第八节参考资料链接。改 QEMU 参数只改这里 |
| | `t490_platform_check.sh` | **★ 平台合规预检**：把第七节逐条变成 35 项 `[PASS]/[FAIL]` 断言，产出 `platform-check.txt`；`RC=0` 才算 `PLATFORM_COMPLIANT` |
| **setup** | `probe_t490.sh` | 环境体检（工具/网络/sudo/磁盘） |
| | `prepare_t490.sh` | 用户级装齐依赖：QEMU 10.2.1（`apt-get download`+`dpkg -x`，绕 sudo）、rust 1.95.0 + 双 target、musl、clone 仓库 |
| | `push_musl_from_wsl.sh` | **musl.cc 在 T490 不可达** → 从 WSL 传 `aarch64-linux-musl-cross.tgz` |
| | `t490_fix_objcopy.sh` | 补 `rust-objcopy`（`llvm-tools-preview` + 软链）——**缺它 `make build` 必失败** |
| | `push_img_wsl_to_t490.sh` | 4GB 预装镜像直传（跳过 guest 内 apk 装包） |
| **build** | `build_xk_t490.sh` | 完整构建链：defconfig → **架构断言** → rootfs → 扩容 4G → uapps → 注入 → `make build` |
| | `t490_swap_img.sh` | 换用预装镜像并补注入（drmprobe + autorun + 99-autostart） |
| | `t490_reinject.sh` | 仅重注 guest 侧脚本（快速迭代） |
| | `p0_apply.sh` + `modify_card0.py` | **P0 补丁**：精确文本替换 + 编译 |
| **run** | `run_session_t490.sh` | 宿主侧会话编排（**预检 → run-session.py**；PATH 注入 `~/qemu-root/usr/bin`） |
| | `autorun_v5.sh` | **guest 侧总控**（v12）：伪造 sysfs、seatd 管理、weston 多路线对照、rpm 日志双写 |
| **probes** | `drmprobe.c` | DRM 探针 v3：open/ioctl errno + libdrm 能力 + **libudev 探针** + process_device 链模拟 |
| | `libseat_shim.c` | LD_PRELOAD 接管 libseat 全 API（绕过 seatd/VT） |
| | `check_scm.sh` / `check_scm_deep.sh` | SCM_RIGHTS 源码核查 |
| | `recon_userptr.sh` / `mount_recon*.sh` / `weston_kms_check*.sh` / `get_libdrm_src*.sh` / `get_weston_src.sh` | 上游源码侦察（UserPtr API、挂载流程、weston/libdrm 关键函数） |
| **rounds**（实验轨迹，只读参考） | `t490_v7..v16*.sh`、`t490_fakesysfs*.sh`、`t490_weston10*.sh`、`t490_*_read.sh` | 每轮实验的注入 + 起会话脚本，按时间顺序记录排查路径 |
| **close**（收口） | `close_A_status.sh` / `close_B_archive.sh` / `close_B2_fix.sh` | 状态核验 / 证据打包归档 / 目录层级修正 |

## 2. 从零复现（新机器）

```bash
# 1) 体检
bash scripts/t490/probe_t490.sh                      # 在 T490 上执行
# 2) 依赖（用户级，零 sudo）
bash scripts/t490/prepare_t490.sh                    # 含 QEMU 解包、rust target、clone
bash scripts/t490/push_musl_from_wsl.sh              # 在 WSL 侧执行（传 musl 工具链）
bash scripts/t490/t490_fix_objcopy.sh                # 补 rust-objcopy + 首次 make build
# 3) 构建 + 镜像准备
bash scripts/t490/build_xk_t490.sh                   # 或直接用冻结镜像（见下）
# 4) 起一轮会话
ssh mo@T490 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh smoke 600 45'
```

**跳过全部装包**：直接用 T490 上已冻结的镜像
`~/x-kernel/images/p0-drmversion-fixed.img`（含 P0 修复内核 + 全部调试工具），
`cp` 成 `disk.img` 后即可起会话。

## 3. guest 侧 autorun（v12）做了什么

| 阶段 | 动作 |
|---|---|
| 0 | **运行时伪造 sysfs**：`/sys/class/drm/card0/{uevent,dev,subsystem}` + `/sys/dev/char/226:0/device/subsystem`（`/sys` 是 memfs，运行时可写） |
| 1 | 诊断：`/dev/dri`、`/dev/fb0`、`/proc/devices`、`drmprobe`（open/ioctl/libdrm/libudev） |
| 2 | 装包守卫：weston 已装则跳过 `bootstrap.sh`（**避免 apk 依赖求解卡 CPU**）；构造 `/dev/tty0 → /dev/tty`；seatd 干净重启 |
| 3 | weston 多路线对照：① shim + `--drm-device=card0`（**主攻**）② seatd + card0 ③ seatd + 绝对路径 ④ shim + strace |
| 4 | headless 对照组（若 backend 存在） |
| 5 | Chromium 安装（**仅在存在 `/root/install-chromium` 标记时**，防止 TCG 下 solver 卡顿） |
| 6 | 日志双写：`/dev/console`（串口实时）+ `/root/autorun.log`（ext4 持久，可 `debugfs` 只读窥视） |

## 4. 已知坑（血泪清单，改脚本前必读）

1. **`--drm-device` 必须用简写 `card0`** —— weston 把它原样传给
   `udev_device_new_from_subsystem_sysname(udev,"drm",name)`，传 `/dev/dri/card0` 会拼出非法 syspath → NULL。
2. **`libseat` shim 里 `enable_seat` 必须延迟回调**（本实现用独立线程 + 100ms）：
   在 `open_seat()` 内同步回调时，weston 的 `b->libseat` 尚未赋值 → 提前失败。
3. **`/sys` 必须在运行时伪造**：镜像里预置的文件会被 memfs 挂载覆盖（挂载早于用户态）。
4. **镜像用 tar 传输**：87MB 证据/4GB 镜像都用单文件 tar/scp + sha256 校验；scp 目录会慢且易断。
5. **写镜像前必停 QEMU**，改完必 `e2fsck -f -y disk.img`；guest 大写入后需 `sync && sleep && sync` 防丢。
6. **T490 上 guest 内 apk 极慢**（依赖求解纯 CPU 且与宿主负载争抢）→ 一律改为
   宿主机跨架构预装（`apk.static --usermode --arch aarch64 --root DIR`）或直接复用冻结镜像。
7. **pre-commit 需要 pinned nightly**（`nightly-2026-03-08`）；本地急用可
   `SKIP_FMT=1 SKIP_CLIPPY=1 git commit`（hook 明确支持），**但上游 PR 前必须补跑全检**。
8. **`autorun` 里的探针循环是固定列表** —— 新增 `.c` 探针后**必须同步加进 autorun 的 `for probe in …`**，
   否则探针被注入了却根本不执行（白跑一整轮，已发生两次）。
9. **判断"某类日志是否消失"必须全局 `grep -c`，绝不能看 tail 窗口** —— 曾据此误判 netlink 修复
   消除了崩溃循环。`autorun_nnp.sh` 已把 `COUNT [...]` 段固化进流程。
10. **console 只保留 head/tail 各 60 行** —— guest 的 `/root/` 是真实磁盘，停机后必须用
    `pull_guest_logs.sh`（`debugfs dump`）把**完整日志**取回，信息量高一个数量级。
11. **前台 `sleep` 会撞 Bash 工具超时** → 窥探远端进度时直接读增量文件，别 `sleep`。
12. **`pkill -f <pat>` 会匹配承载它的 ssh shell 自己**（命令行含同样字符串）→ 自杀（exit 127）。
    用字符类规避：`pkill -f "qemu-syste[m]"`。

---

## 5. 当前工作流（2026-09-21 起，取代早期手写注入脚本）

```bash
# ⓪ 平台合规预检（改内核/换机器/换 QEMU 后必跑；只读）
ssh mo@T490 'bash ~/xk6/scripts/t490/t490_platform_check.sh ~/xk6/tmp/check.txt; echo RC=$?'
#   期望 RC=0 且 PLATFORM_COMPLIANT
# ① 打补丁（幂等、精确匹配、不盲改）
ssh mo@T490 'python3 ~/xk6/scripts/t490/p3_prctl_nonewprivs.py ~/x-kernel'
# ② 构建
ssh mo@T490 'export PATH=$HOME/.cargo/bin:$PATH; cd ~/x-kernel && make build'   # 期望 BUILD_EXIT=0
# ③ 一轮会话：注入任意探针 + 任意 autorun，然后跑
#    ★ 平台参数已收敛到 platform.env，这里不必再传 GRAPHIC/ACCEL/MEM/SMP
ssh mo@T490 'cd ~/xk6; BASE_IMG=$HOME/x-kernel/images/pkg-installed.img \
  PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh <tag> <dur> <ival> <autorun.sh> [probe.c …]'
# ④ 停机后回收 guest 完整日志（★ console 只有 tail 窗口，不够用）
ssh mo@T490 'bash ~/xk6/scripts/t490/pull_guest_logs.sh <tag>'
```

> ③ 结束时证据目录应含 **8 个文件**：`env.txt console.log cmd.txt timestamps.csv
> manifest.txt platform-check.txt platform-compliance.txt` + `screenshots/`。
> 其中 `platform-compliance.txt` 必须为 `PLATFORM_COMPLIANT`（`FAIL=0`），否则该轮数据不得作为评分证据。

### 补丁应用器（截止 2026-09-21，全部幂等）
| 脚本 | 补丁 | 落点 | 状态 |
|---|---|---|---|
| `p1_stream_ancillary.py` | **P1** AF_UNIX SOCK_STREAM 的 SCM_RIGHTS 收发 | `net/knet/src/unix/{stream.rs,stream/channel.rs}` | ✅ 已验证 |
| `p2_sched_netlink.py` | **P2-a** `scheduler_target` 按 tid 解析<br>**P2-b** netlink `bind` 接受 `groups != 0` | `core/ksyscall/src/task/sched.rs`<br>`net/knet/src/netlink/socket.rs` | ✅ 已验证 |
| `p3_prctl_nonewprivs.py` | **P3** `prctl(PR_SET_NO_NEW_PRIVS)` 由 ENOSYS 改为真语义 | `core/ksyscall/src/task/ctl.rs` | ✅ 已验证 |
| `p4_madvise.py` | **P4** `madvise` advice 白名单 + 允许跨洞 DONTNEED | `posix/mm/src/mmap.rs`<br>`mm/memspace/src/aspace.rs` | ✅ 探针 4 项转正（未解决 renderer） |
| `p0_apply.sh` + `modify_card0.py` | **P0** `DRM_IOCTL_VERSION` 的 NULL 指针 | `io/drmdevice/src/card0.rs` | ✅ commit `8162e8a` |

### 探针（`probe.c`，由 `t490_round.sh` 交叉编译并注入到 `/`）
| 探针 | 验证目标 | 判定行 |
|---|---|---|
| `nvprobe.c` | P3：`prctl` 语义 + fork 继承 + **逐字复刻 LaunchProcess 判据** | `[NV] T1..T5 … PASS`、`[RESULT] ALL_PASS` |
| `p2probe.c` | P2：子线程 tid 的 `sched_getparam` + `bind(nl_groups!=0)` | `[RESULT] ALL_PASS — P2 两处修复均生效` |
| `fdprobe.c` | P1：SCM_RIGHTS 跨进程 fd 传递（T1–T4） | `[Tn] VERDICT_PASS` |
| `childprobe.c` | Chromium 子进程启动通路（`/proc/self/exe`、fork、execve） | `[C1..C5] … PASS` |
| `evprobe.c` | evdev 归类（EVIOCGNAME/EVIOCGID/EVIOCGBIT） | `[EVSUM]`、`[EVMAP]` |
| `drmprobe.c` | DRM open/ioctl errno + libdrm/libudev 能力 | `VERDICT_*` |

### 本轮新增 autorun
| 文件 | 场景 |
|---|---|
| `autorun_install.sh` | 装包 + weston + Chromium（A/B 两种启动尝试） |
| `autorun_nnp.sh` | **P3 验收轮**：探针 + weston + Chromium + **全局 `COUNT` 段** |
| `autorun_r2.sh` | **renderer 追击**：A 段多进程+屏蔽网络 / B 段 `--single-process` |
