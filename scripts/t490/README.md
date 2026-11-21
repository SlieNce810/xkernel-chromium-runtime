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
| **设备暴露** | 用户固定要求不限制 GPU/输入/块/网卡等设备 | 保留 `virtio-gpu`、键鼠、`virtio-blk`、`virtio-net` 与 `virtio-rng`；T490 无 `/dev/vhost-vsock`，故 `PLAT_VSOCK=n` 防止 QEMU 启动失败 | 不使用 `-nodefaults` 或设备过滤参数 |
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
   `MEM ?=` 为空 → xkmake 默认 `-m 1g`。本项目固定显式传 `GRAPHIC=y ACCEL=n MEM=2g SMP=4`，以满足赛题的 2G 内存要求。
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
| | `ensure_swap.sh` | T490 宿主 swap 前置：默认确保 12 GiB 名义容量，记录 `swapon --show`/`free -h`；只缓解 TCG/构建内存压力，不计入浏览器得分 |
| | `ipc_endpoint_report.py` | 按 zygote fork fd、socketpair/inode 和 child/browser peer IPC 关联 renderer bootstrap；区分 fd 复用与真实 endpoint 活动 |
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
| **pages**（页面与判据） | `t490_inject_pages.sh` | **★ 官方三页套注入器**：整套写盘 + 读回逐字节自证 + 入口白名单校验 |
| | `t490_inject_pages_dryrun.sh` | 注入器本地干跑台（桩 `debugfs`，无需镜像；期望 19/19） |
| | `ppm_assert.py` | **★ 像素判据**：`--profile legacy`（自建页 v1.1）/ `official-{index,layout,interaction}`（组委会三页，常量来自参考图实测）；含差图模式 |
| | `ppm_assert_selftest.py` | **★ 判据三重对照自检**（正 / 跨页负 / 合成负 / 真实历史负；含定向破坏） |
| | `page_measure.py` | 几何测量器：颜色块 bbox + 行带扫描（判据常量的取值工具） |
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
#    ★ 测试页自 2026-09-22 起是「官方三页套」，默认整目录注入（见 §5.1）
ssh mo@T490 'cd ~/xk6; BASE_IMG=$HOME/x-kernel/images/pkg-installed.img \
  bash ~/xk6/scripts/t490/t490_round.sh <tag> <dur> <ival> <autorun.sh> [probe.c …]'
#    换要测的页面（默认 index.html）：
#    PAGE_URL=file:///usr/share/html-test/layout.html bash … t490_round.sh css 600 120 autorun_v5.sh
# ④ 停机后回收 guest 完整日志（★ console 只有 tail 窗口，不够用）
ssh mo@T490 'bash ~/xk6/scripts/t490/pull_guest_logs.sh <tag>'
```

> ③ 结束时证据目录应含 **8 个文件**：`env.txt console.log cmd.txt timestamps.csv
> manifest.txt platform-check.txt platform-compliance.txt` + `screenshots/`；
> 走 `PAGE_DIR` 页面集注入时再多一个 **`pages.txt`**（页面清单 + 写盘读回自证）。
> 其中 `platform-compliance.txt` 必须为 `PLATFORM_COMPLIANT`（`FAIL=0`），否则该轮数据不得作为评分证据。

### 5.1 测试页（官方三件套）与判据档

> 完整说明见 `scripts/testpage/README.md` 与 `report/26`。

| 项 | 值 |
|---|---|
| 页面集 | `scripts/testpage/{index,interaction,layout}.html`（组委会 v1.0） |
| 注入 | `t490_inject_pages.sh`：整套写盘 → `/usr/share/html-test/`，并 `debugfs dump` **读回逐字节自比**；失败即硬退 |
| 入口 | `PAGE_URL`（白名单：三页之一），默认 `file:///usr/share/html-test/index.html`；注入时烘焙进 autorun 副本 |
| 判据 | `ppm_assert.py --profile official-index｜official-layout｜official-interaction`（常量全部来自参考图实测） |
| 测量 | `page_measure.py`：颜色块 bbox + 行带扫描（新页面集到来时用它重新取常量） |
| 自检 | `ppm_assert_selftest.py`（四类对照，期望 **28/28**，真实负对照取 3 张时 34/34）；`t490_inject_pages_dryrun.sh`（桩 debugfs 干跑，期望 **19/19**） |

三条必须记住的页面事实（实测）：

1. `index.html` 是**无脚本静态页** → 不能对它做双帧差分（必然 0 差异），JS 证据看结论条颜色；
2. `interaction.html` 的自检**必须有一次真实点击**（未点击时结论条是灰的）；
3. `layout.html` 的"6/6 通过"结论条在整页 y≈1450 处，1280×800 的 screendump **看不到**。

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
| `evdev_sniff.c` | 不抢占 event fd，旁路观察输入事件，用于区分 virtio-input/evdev 与 libinput/Weston 问题 | `EVDEV open_returned`、`EVDEV ev`；正式轮须把探针输出保存在 console 证据 |
| `summarize_futex_trace.py` | 将内核 `CHROMIUM_FUTEX_CALL/RESULT` 按 sequence 配对，并统计无参数通用 syscall error | `python3 scripts/t490/summarize_futex_trace.py console.log --out futex-trace-summary.json` |
| `compatprobe.c --inotify-timerfd` + `autorun_inotify_timerfd.sh` | inotify watch/create/read 与 timerfd create/set/poll/read 的同源 Linux/x-kernel 对照 | `[CP] ... PASS/FAIL`、`[CPSUM]`、`[RESULT]`; 用 `t490_round.sh <tag> 300 60 autorun_inotify_timerfd.sh compatprobe.c` 注入运行 |
| `compatprobe.c --scm-rights-shortread` + `autorun_scm_rights_shortread.sh` | AF_UNIX SOCK_STREAM 中 SCM_RIGHTS 首字节交付与 100 次单字节读取 | `[CP]` 首读需有 1 个 fd、后续读取需 0 个 fd，payload 需完整；用 `t490_round.sh <tag> 300 60 autorun_scm_rights_shortread.sh compatprobe.c` 注入运行 |
| `procfs_memory_probe.c` + `autorun_procfs_memory_probe.sh` | anon/file/shared 映射、触页、fork、COW、unmap，并采集 statm/status/smaps_rollup | Linux 输出 RSS/PSS/USS 原始字段；缺失的 smaps_rollup 字段明确写 `UNAVAILABLE`。用 `t490_round.sh <tag> 300 60 autorun_procfs_memory_probe.sh procfs_memory_probe.c` 注入运行 |
| `autorun_compat_memory_bundle.sh` | 将以上三个 focused probe 置于同一 QEMU guest 会话，方便和同源 T490 host baseline 成对复核 | 需同时注入 `compatprobe.c procfs_memory_probe.c`；总摘要为 `[COMPAT_BUNDLE] RESULT overall_rc=0/1` |
| `drmprobe.c` | DRM open/ioctl errno + libdrm/libudev 能力 | `VERDICT_*` |

`run_input_final.sh` 的 `EVDEV_PROBE=0` 可用于不注入旁路 observer 的 cold-start 对照；页面 ready 超时会先用 QMP quit 结束会话。`interaction_score_driver.py` 在目标 viewport 内轮询键盘回显，最多等待 120 秒；R11 观察到 HMP step4 光标落点向右下漂移。R17/R18 的原始 PPM 差分隔离出 step3 指针热点，R19 的两点线性外推却把指针送出 viewport；R20/R21 又显示同一请求会随前序动作改变落点。当前 step3 默认保留 R18 最后一个在屏候选 `(250,588)` / `(350,710)`；可用 `INTERACTION_COUNTER_TARGET=x,y`、`INTERACTION_NAV_TARGET=x,y` 单轮覆盖。另可按顺序设置 `INTERACTION_COUNTER_RETRY_TARGETS='x,y;x,y'`，driver 每次真实点击后立即检查计数 ROI，只在未变化时重试，首个过门截图作为 `after-mouse-click.ppm`。这些是 HMP 相对移动请求值，不是屏幕绝对坐标。R22 原始截图显示旧计数 ROI 把光标形状当成了数字变化；gate 现只检查粗体数字 ROI `555,625,570,650`，并有 pointer-only 负例与数字变化正例测试。

### Chromium 启动 trace 采集试探

用于确认正式性能事件能否从 Chromium 的单调时钟 trace 中提取；该命令是 diagnostic-only，不作为稳定性或性能样本：

```bash
bash scripts/t490/run_chromium_trace_probe.sh --dry-run trace-startup-precheck
bash scripts/t490/run_chromium_trace_probe.sh 2026-11-20-candidate-perf-trace-r1
```

它启动一次2 GiB、Wayland、默认 Browser→Zygote→Renderer 会话，保存500秒 Chromium startup trace 到 guest `/root/mp-perf-trace.json`，并显式设置 `--trace-startup-format=json`。事件类别包括 startup、ipc、loading、blink、cc、viz、navigation，以覆盖浏览器启动、导航、renderer launch 和画面提交。结束前 exporter 等待源文件大小/SHA连续稳定，再写独立gzip临时文件并执行 `gzip -t`；输出前校验 base64 字符数、解码后与压缩文件逐字节相同，并再次执行 `gzip -t`；串口以256字符base64块发送，每块带连续序号和长度，BEGIN带原始及gzip长度/SHA，END带总块数，每16块短暂节流。末尾折行不带换行符时，块数按awk记录数计算，读取循环仍会发送EOF前的最后一块。为适应较大的navigation trace，probe诊断保持650秒，guest观察上限1400秒；主机周期截图间隔1200秒（首次截图仍为240秒），并关闭额外的内核 syscall trace。`t490_round.sh` 仅在 `ALLOW_CHROMIUM_PERF_TRACE_ONLY=1` 且附加参数完整匹配固定 probe 值时，允许该 trace-only 组合。`round_assert.sh` / `pull_guest_logs.sh` 仍从当前 `KERNEL_DIR/disk.img` 尝试回收持久文件。JSON模式可用 `python3 scripts/t490/extract_perf_trace.py console.log --run-id <tag> --out trace.json` 校验块序、块长度、总块数、压缩SHA、gzip、原始长度、SHA和 `traceEvents`；对proto输出，用 `--format raw --out trace.pb` 在同等传输完整性校验后保留字节，供Perfetto工具读取。试采结果是diagnostic-only，不能进入before/after统计。

首次 R1 试采发现 `autorun_mp_score_observe6.sh` 没有把 `EXTRA_FLAGS_VALUE` 拼进 `CHROME_ARGS`，所以虽请求了 `--trace-startup`，实际 argv 无此参数；模板现已补 `EXTRA_FLAGS` 占位符，probe 会在dry-run之前验证参数注入。R2 已确认参数生效但guest文件未回收。R3证明串口导出可传输完整trace主体，但周期截图状态文字打断一块数据，抽取器因此拒绝该trace；R4已加入块序号、块总数和明确的gzip失败处理，并把周期截图移出传输窗口。R1/R2/R3均不作为性能样本。R15 真实 Chromium trace 首次完成完整 serial round-trip（25,894 events、3,408 chunks），但同轮全树 RSS/PSS/USS sampler 在 10 个实例下 158 次 missed、状态 FAIL；详见 [report 386](../../report/386-T490二GiB真实Chromium首次帧trace成功但树内存采样超时R15-20261120.md)。 R17 trace-off 页面通过后采样仍 missed 213，需优化 PFN mapcount 查询再做同条件复测，见 [report 388](../../report/388-T490二GiB无traceChromium内存采样仍超时R17-20261120.md)。 R18 的 dense PFN count 补丁已构建，procfs memory probe 9阶段回归 rc=0；R19 同条件对照提高 sample ID、降低 missed 和 overrun 中位数，但尾部超时更长且 status 仍 FAIL，不能认定可靠收益，见 [report 389](../../report/389-T490densePFNmapcount候选构建及PSS-COW回归R18-20261120.md) 与 [report 390](../../report/390-T490densePFN真实Chromium单变量内存对照R19-20261120.md)。
R20 在相同 trace-off dense PFN 条件下复测，sample ID/missed/median overrun 与 R19 方向一致，但两轮均 status FAIL 且 page-ready/P95 退化；dense 候选继续保留为实验，不写入收益结论，详见 [report 391](../../report/391-T490densePFN同条件Chromium内存采样重复对照R20-20261120.md)。
R21 为该 endpoint 加入分阶段 guest-monotonic 计时，首页 strict 589.187秒、重载1/1、诊断保持800秒通过；900秒 memory sampler 仍FAIL（232个sample ID、208 missed、276错误），所以没有有效内存峰值。计时显示resident-page walk中位212ms/P95 1.599秒，PFN mapcount中位11ms/P95 48ms；R21只用于定位resident walk热点，不构成优化收益。patch、源/二进制哈希和完整统计见 [report 392](../../report/392-T490procfs阶段计时与R21Chromium进程树采样诊断-20261120.md)。
R22 可用 `STABILITY_LIFECYCLE_PRELOAD=1` opt-in 编译/注入 `lifecycle_event_preload.c`；探针预期观测 Browser/Renderer 主线程等待、file URL open 和 Zygote fork，并将可选 `lifecycle-probe-events.jsonl` 放入 memory export。R22 实际只捕获了 file open 和 5 个 Zygote fork 边界，没有 Browser/renderer ready 或 first-frame。用 `python3 scripts/t490/merge_lifecycle_events.py --memory-events <memory-export/lifecycle-events.jsonl> --probe-events <memory-export/lifecycle-probe-events.jsonl> --stability-events <stability/stability-events.jsonl> --evidence-dir <evidence-dir> --out <new-ledger.jsonl> --summary <new-summary.json> --run-id <tag>` 合并 guest 事件与 QMP strict verdict；缺少的事件会使 summary 标为 invalid，fork 边界不会被误当成已确认的 renderer-create 事件。详见 [report 393](../../report/393-T490guest单调生命周期preload事件探针R22缺失BrowserRendererReady-20261121.md)。
R23 以 `CrBrowserMain` / `CrRendererMain` comm 及 poll/ppoll hook 补测，捕获 Browser ready 与 guest file-open 导航，startup候选42.290秒；renderer ready、first frame仍缺。R23页面严格通过为987.609秒host elapsed，900秒clock sync无法映射该页事件；采样器状态FAIL。R23实际运行用的是每次等待都读procfs的旧preload；源码已加一次性快路径，但尚未guest A/B验证，详见 [report 394](../../report/394-T490guest生命周期hook补覆盖与R23首屏及clock-sync缺口-20261121.md)。

R24 实际使用冻结根 /home/mo/x-kernel，但在约六分钟后因错误的路径判断被提前终止，未完成首页strict。R23及R25–R35使用 xk-compat-fix-r1 alternate worktree，只作机制诊断，不计正式基线或性能统计。范围更正见 [report 395](../../report/395-T490R24启动路径偏差与提前终止记录-20261121.md) 与 [report 407](../../report/407-T490冻结基线路径与R23-R35实验范围更正-20261121.md)。

R26 900秒 sampler 已完整导出并由仓库当前 extractor 验证；Browser launch→main-loop-ready 为39.594秒，navigation→strict screenshot上界517.017秒。renderer-ready/first-frame缺失，内存仍因213 missed及271错误而FAIL，不是有效四指标样本。T490 的辅助 extractor 副本旧于仓库版本，遇到新增可选probe成员会拒绝，复现时应使用当前 checkout 的 `extract_perf_memory.py`。详见 [report 397](../../report/397-T490R26Browser启动导航上界与内存采样复测-20261121.md)。

R27 为 `resident_page_frames()` 去掉每个 present leaf 的重复 `query()`，page-table单测11/11通过。resident-walk中位/P95下降，但总 sampler仍FAIL且误差项混合，因此只保留可回退补丁，不列为已接受收益；须待完整1 Hz采样通过后做五次交替复测，详见 [report 398](../../report/398-T490resident-walk直取PTE基址机制对照R27-20261121.md)。

R28 把存活进程 role/comm 重检降到5秒一次，AArch64 `-Werror` 静态编译通过；内存 sampler仍1 Hz。页面strict、重载和420秒保持通过，但 memory export 151块仅收到145块、缺 END，数据不可解包。R29把窗口改为850秒以给导出留余量，详见 [report 399](../../report/399-T490R28sampler角色重检降频与串口截断记录-20261121.md)。

R29 将850秒bundle完整解出，sampler仍FAIL（225 sample IDs、205 missed、268错误）。R27/R29 sample-work中位/P95方向向好，但单轮且窗口长度不同，不能记为收益；R30保持同一 role cadence 并恢复900秒窗口，拉长诊断保持以区分采样终点和传输结束，详见 [report 400](../../report/400-T490R29采样窗收缩与role重检机制复测-20261121.md)。

R30 的900秒 sampler完整导出，但指定页面strict在1550秒deadline前未过；240秒画面停留在Weston，1440秒与timeout截图为空白，Browser/Weston进程仍存活。该轮按页面失败处理。R31将关闭sampler与lifecycle preload，仅复现默认多进程Wayland页面启动，隔离观测负载影响，见 [report 401](../../report/401-T490R30默认多进程页面strict超时空白屏复现-20261121.md)。

R31 关闭sampler/preload/guest clock-sync后首页、1/1重载与420秒保持strict通过；因同时关闭多项观测，只能确认最小页面路径可用，不能定位R30失败来源。R32在此基础上单独开启sampler，继续单变量隔离，见 [report 402](../../report/402-T490R31关闭采样探针后的最小页面复现-20261121.md)。

R32 在sampler-only配置下首页strict同样超时，虽然内存bundle完整导出；sampler仍FAIL且页面未通过，不能报告peak。R31 sampler-off轮通过，提示观测负载相关但尚未证明因果；R33重复sampler-off基线后再安排后续单变量，详见 [report 403](../../report/403-T490R32仅启用内存采样时页面strict超时-20261121.md)。

R33 sampler-off 重复控制也通过页面 strict、1/1重载与420秒保持；guest clock-sync关闭，normalizer报告family快照stale，故不用于guest-clock性能或稳定性总PASS。R31/R33最小配置通过而R30/R32 sampler-on失败，仍需重跑和 IPC/frame诊断，不能单因果归因。详见 [report 404](../../report/404-T490R33sampler-off重复页面控制与时钟口径-20261121.md)。

`run_stability_round_mp.sh` 新增 `STABILITY_PROCESS_SAMPLE_SECONDS`，默认5秒、最多60秒；用于控制 autorun 的 shell process-tree scan 频率。R34 以30秒process scan和30秒family watchdog运行：页面通过，R32的5秒process scan页面超时，但R34 sampler仍FAIL、family snapshot间歇36秒stale。作为降低观测负载候选，需与正常1Hz采样和30秒freshness门限再测，见 [report 405](../../report/405-T490R34sampler与30秒process观察扫描对照-20261121.md)。

R35 将 process-tree scan设为30秒、family watchdog设25秒，并开启clock-sync、lifecycle preload与900秒sampler；首页、重载、600秒保持和event normalizer通过。Browser start候选38.511秒，页面截图上界436.389秒；sampler仍FAIL且renderer-ready/first-frame缺，不能报告内存峰值或四指标PASS，详见 [report 406](../../report/406-T490R35低频Observer完整采集路径复测-20261121.md)。

R36 使用baseline freeze r3冻结根 /home/mo/x-kernel（kernel SHA 51c4…）、2 GiB pure TCG，并确认Jitless/IPC timeout flags；首页strict在1550秒diagnostic deadline超时，Browser/Weston仍存活。旧三次冷启动通过需在默认2400秒ready timeout下复核，见 [report 408](../../report/408-T490冻结根51c冷启动strict超时R36-20261121.md)。
R37 在冻结根kernel `51c402…`、rootfs `bab5c9…`、2 GiB下使用默认2400秒ready deadline，通过首页strict、1/1真实重载及420秒保持；但5个family snapshot因38.675–43.023秒间隔超过35秒freshness门限，normalizer失败，因此不算完整稳定性通过，详见 [report 409](../../report/409-T490冻结根R37coldstart页面通过但family快照stale-20261121.md)。
R38 将family watchdog改为15秒，冻结根首页strict 497.171秒通过、1/1重载及420秒保持通过；normalizer 267/267通过，14个host liveness检查的family freshness最大30.715秒。但本轮为diagnostic-only、正式gate跳过，且未采集guest-clock性能/内存峰值，详见 [report 410](../../report/410-T490冻结根15秒familywatchdog冷启动与保持通过R38-20261121.md)。
R39 同一冻结kernel/rootfs独立复跑，首页strict 466.289秒、真实重载1/1、保持420秒均通过；normalizer 256/256通过，14个host liveness检查family freshness最大30.029秒。仍为diagnostic-only，不计正式30分钟验收或性能数据，详见 [report 411](../../report/411-T490冻结根独立冷启动复现与freshness通过R39-20261121.md)。
R40 在同一2 GiB冻结根、15秒family watchdog配置下，首页strict默认2400秒超时；Weston/Browser仍活、normalizer 793/793通过，但78个process-family snapshots最大间隔93.572秒。它不计冷启动成功/正式稳定性gate，详见 [report 412](../../report/412-T490冻结根默认deadlineR40strict页面超时-20261121.md)。
R41 首页strict 466.226秒通过，真实Ctrl+R nav-01在90秒窗口超时（reload 0/1），但420秒观察保持和266/266事件normalizer通过。它是第三次初始strict首页通过，不是完整稳定性通过；详见 [report 413](../../report/413-T490冻结根R41首页通过但CtrlR重载超时-20261121.md)。
R42 正式稳定性gate运行：首页465.976秒strict通过，nav-01至08通过，nav-09 timeout，driver hold 1805.000秒通过但最终8/10且gate fail；normalizer 746/746通过、family age最大30.022秒。详见 [report 414](../../report/414-T490冻结根正式稳定性R42八次重载与1805秒保持但nav09超时-20261121.md)。
R43 同参数正式复跑：首页497.108秒strict通过，nav-01/02通过、nav-03超时，之后保持1805.000秒通过；normalizer 739/739通过、family freshness最大28.895秒，但正式gate因只有2/10 reload失败。详见 [report 415](../../report/415-T490冻结根正式稳定性R43两次重载后nav03超时-20261121.md)。
R44 正式冻结根stable gate PASS：初始页497.079秒strict通过，真实Ctrl+R 10/10通过、保持1805秒，QEMU liveness 60样本，family age max30.024秒且无进程退出/guest异常。sampler/preload/guest clock sync关闭，不能算内存或四项性能样本，详见 [report 416](../../report/416-T490冻结根正式稳定性R44十次reload与1805秒保持通过-20261121.md)。
R45 开启lifecycle preload、guest clock sync和900秒sampler后：首页、reload和420秒诊断保持通过；Browser startup单轮候选39.769秒、导航至strict screenshot上界410.029秒。缺renderer-ready/first-frame，memory sampler0 rows/734 missed/1,357错误，不计正式四指标。空CSV bundle保留修复见 [report 417](../../report/417-T490R45lifecycle与内存采集诊断采样器零有效行-20261121.md)。
R46 在冻结tracked snapshot上应用四个procfs resident-page补丁并构建成功，2 GiB shell sampler自报8次/16行/0 missed；当轮调用的旧runner未输出完整CSV/events，严格提取拒绝，见 [report 418](../../report/418-T490冻结基线procfs驻留页候选R46%20smoke与原始归档缺口-20261121.md)。
R47 将仓库runner同步到隔离目录后完成CSV/events串口输出；身份检查发现冻结snapshot `/proc/<pid>/stat` field 22为0（`5-0`/`11-0`），提取器正确拒绝；修复补丁为 `patches/compat/proc-stat-starttime.patch`，见 [report 419](../../report/419-T490R47冻结procfs候选身份复核发现stat22为零-20261121.md)。
R48 在同一冻结快照将stat22补丁与四个驻留页补丁一起构建；root/child ticks非零，8次/16行RSS/PSS/USS smoke完整提取，0 missed。没有启动图形或Chromium，不计四指标。提取器现在将可选kernel timing `UNAVAILABLE` 原样保存并标注不可用，Shared/USS显式0是合法数值；专用测试10/10，全Python suite 77/77，见 [report 420](../../report/420-T490R48冻结快照stat与进程树内存smoke提取通过-20261121.md)。
R49 候选在相同平台启用 timing patch、lifecycle preload、guest clock-sync 与900秒sampler；首屏1800秒deadline超时，53张1280×800截图全部strict失败。稳定性事件normalizer 1174/1174通过，但900秒memory bundle缺失seq32–47，264块中仅248块收到，严格解包拒收；同时console记录 `MP_LEDGER_LIMIT` 的跨进程procfs阻塞提示。该轮不计性能/稳定性PASS；先降低诊断输出并修复串口完整性，再继续分析页面时序，见 [report 421](../../report/421-T490R49阶段计时与lifecycle采集诊断首屏超时串口缺块-20261121.md)。
R50 在同一R49 candidate kernel/rootfs/page下关闭memory sampler、lifecycle preload与guest clock-sync，保留family/process liveness observer；首屏仍在1800秒deadline超时，59次poll/53张截图均strict失败，normalizer567/567通过。此控制显示R49失败不能归因于三项高负载观察开关的组合；因为三项同时关闭，不能单项归因。该kernel仍不是R44冻结PASS kernel，也没有memory/performance指标，详见 [report 422](../../report/422-T490R50观测关闭控制仍首屏超时-20261121.md)。

### 进程树 RSS/PSS/USS 采样器

`proc_tree_sampler.c` 优先读取 `/proc/<root-pid>/tree_smaps_rollup`，通过一次全进程 resident-frame/mapcount 快照取得目标进程树各 PID 的 RSS/PSS/USS，并核对 PID/PPID 关联；端点不存在时才回退到逐 PID `smaps_rollup`。任一已发现进程缺少数值、父链不匹配或页面统计不可用时，该轮样本整体无效。状态文件和结果行记录实际来源，缺失值不会填零。端点实现及 `/proc/<pid>/stat` field 22 起始 tick 修复见 [report 383](../../report/383-T490-proc-stat-starttime与进程树内存单遍回归-20261120.md)。R13 2 GiB guest smoke 仅有两个 shell 进程，8 次采样/0 missed；这验证了工具路径，不代表 Chromium 进程树性能数据。R14 起 smoke 会以 `PROC_TREE_SMOKE_MEMORY_CSV_BEGIN` / `PROC_TREE_SMOKE_EVENTS_BEGIN` 标记完整串口块；用 `python3 scripts/t490/extract_proc_tree_smoke.py <console.log> --run-id proc-tree-smoke-01 --out-dir <new-dir>` 校验并提取 CSV、事件、状态和 root stat。对应回归见 [report 384](../../report/384-T490-procfs-smoke原始数据串口回收与严格提取-20261120.md)。

R21 新增的 CSV 后缀字段按 sample ID 聚合 `tree_snapshot_total_ns`、resident walk、mapcount、rollup、format、procfs read 和采样前置工作时间；原10列 CSV仍可读。`tree_snapshot_process_count` 计的是全系统 mapcount 输入，`tree_snapshot_resident_pages` 是含共享映射重复数的mapping计数，不能与Chromium树行数比较。复现提取命令：`python3 scripts/t490/extract_perf_memory.py <console.log> --run-id r21-dense-timing --out-dir <new-dir>`；无效样本会保留原始数据并在 `extraction.json` 中标记 `valid=false`、error types 与 overrun min/median/P95/max。阶段计时 patch 和口径见 [report 392](../../report/392-T490procfs阶段计时与R21Chromium进程树采样诊断-20261120.md)。

smoke extractor 接受基础10列CSV、带有效计时扩展的19列CSV，以及带全部 `UNAVAILABLE` 扩展计时列的19列CSV；后者保留字面标记且在 summary 中写 `tree_snapshot_timing.available=false`。同一轮计时列半缺、跨样本可用性变化、零field22、缺CSV行或非数值内存值仍拒收。RSS必须非零；PSS/USS/Shared为显式非负数值时保留，包括 `Shared=0`。


R12 的候选坐标 `(247,607)` / `(292,638)` 仍未命中；后续校准应减小相对步幅并降低事件频率，再按截图校准坐标。

R13 可设置 `INTERACTION_POINTER_MODE=step1`（单像素、50 ms 间隔），R14 显示它未到达按钮且页面后来出现 unresponsive 对话框。R15 使用 `step3` 后实际打开了 CSS 页面，但 strict gate 未看到页面顶部；R17 的 Home 键也未使截屏回到顶部。R17 请求 `(212,638)` 后指针热点为 `(253,724)`；R18 请求 `(250,588)` 后热点为 `(302,729)`，计数和导航仍未通过。R19 的外推请求 `(233,1138)` / `(287,778)` 把指针移出 viewport，详见 report 322。后续只作小步单变量调整，`test_interaction_score_driver.py` 检查步进、目标映射和覆盖值。

R52 将direct-PTE patch在冻结快照上重建并observer-off复跑：首屏1800秒超时，53张截图strict失败，normalizer592/592通过。结合R50 direct-on失败与R51 direct-off首屏/reload/420秒hold通过，这一回归方向已在两个direct-on构建中重现；仍需要在no-direct版本补正式稳定性和功能回归，见 [report 424](../../report/424-T490R52direct-PTE回加重复复测首屏仍超时-20261121.md)。

R53 no-direct-PTE候选把Kconfig日志从WARN降到ERROR后跑正式验收门槛；runner dry-run通过，但initial strict在2400秒超时，没有进入10次reload/1805秒保持。normalizer871/871通过，timeout时Weston/Chrome存活，低噪声console约168 KB。此设置没有独自修复页面；该轮gate失败，详见 [report 425](../../report/425-T490R53ERROR日志候选正式稳定性首屏超时-20261121.md)。
R54 同一no-direct-PTE/ERROR-only候选正式稳定性PASS：initial strict、真实QMP Ctrl+R 10/10、1805秒hold、60 liveness、0退出/异常；normalizer762/762。原runner因staged source路径计算错误而把正式gate误报RC1；更新后的 `stability_gate.py --checker` 用同一证据重验pass，并修复runner总是将 `$HERE/ppm_assert.py` 显式传入。R54不含memory/lifecycle performance数据，三次独立启动和一键复现仍待补齐，见 [report 426](../../report/426-T490R54no-directPTE-error候选正式稳定性通过并修复checker路径-20261121.md)。

### 本轮新增 autorun
| 文件 | 场景 |
|---|---|
| `autorun_install.sh` | 装包 + weston + Chromium（A/B 两种启动尝试） |
| `autorun_nnp.sh` | **P3 验收轮**：探针 + weston + Chromium + **全局 `COUNT` 段** |
| `autorun_r2.sh` | **renderer 追击**：A 段多进程+屏蔽网络 / B 段 `--single-process` |

R51机制对照：R50含direct-PTE patch时observer-off首屏1800秒超时；R51基于同冻结快照和其余相同补丁、去掉direct-PTE后首页466.008秒strict通过、reload 1/1、420秒hold通过。normalizer有4个family freshness超限快照，所以此轮不是稳定性总PASS；只把direct-PTE视为回归候选，R52需回加patch复跑，见 [report 423](../../report/423-T490R51不含direct-PTE候选页面及重载通过但freshness失败-20261121.md)。
