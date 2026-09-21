# 15 · 赛题第七、八章 ↔ t490 QEMU 配置同步核验

> **核验日期**：2026-09-21 21:09–21:35（GMT+8）
> **核验依据**：《赛题六》PDF **第七节 统一评测平台与测量规范**、**第八节 参考资料**
> **核验对象**：t490 工作流中承载 QEMU 平台配置的全部文件（本地 `E:\02_competition\中电杯`
> 与 T490 `mo@10.249.63.140:~/xk6`，两侧 md5 已确认一致）
> **核验方式**：PDF 全文提取 → 逐条比对 → 修正 → T490 实机预检 + 跑一轮真会话验证
> **结论一句话**：**QEMU 命令行本身已 100% 合规（此前只是没被证明）**；
> 真正的缺口在**证据链**——`env.txt` 的 git 追溯字段恒空、`cmd.txt` 不含字面 QEMU 命令行，
> 这两条正好打在第七节(二)3 与第六节(一)「完整运行命令」的复核要求上。**均已修复并实机验证**。

---

## 0. 结论先行

| # | 结论 | 证据 |
|---|---|---|
| 1 | QEMU 机型/参数/设备组合**全部符合**第七节(一)1/2/3 | `evidence/2026-09-21_t490-platverify/platform-check.txt`：**PASS=35 FAIL=0 WARN=1** |
| 2 | **`env.txt` 的 `git_describe`/`git_commit` 恒为空** —— 20/25 份历史证据目录都空（违反第七节(二)3） | 修复前后对照见 §3.1 |
| 3 | **`cmd.txt` 不含字面 `qemu-system-aarch64 …` 行** —— 评委只能看到 2 类 virtio 设备（违反第六节(一)） | 修复前后对照见 §3.2 |
| 4 | QEMU 参数**散落 4 处**、`build_xk_t490.sh` **无架构断言** —— 存在静默构建错架构的风险 | 修复：`platform.env` 单一真源 + §3.3/§3.4 |
| 5 | 修复后重跑真会话：命令行 15 项断言 **PASS=15 FAIL=0**，`cmd.txt` 可见 **5 类 virtio 设备 / 0 个 `-accel`** | `platform-compliance.txt` + `cmd.txt` |

---

## 1. 依据原文（PDF 提取，逐字）

### 1.1 第七节（一）统一评测平台

| 条款 | 原文 |
|---|---|
| 1 | 架构与配置：统一采用 **AArch64 QEMU 虚拟平台**（x-kernel **kplat-aarch64** 平台及组委会发布的 **qemu_defconfig** 基线配置），**不接受其他架构平台参赛**。 |
| 2 | QEMU 规格：**qemu-system-aarch64 版本不低于 8.0**。全部评分数据必须出自**纯 TCG 软件模拟环境**，初赛阶段统一**禁用 KVM/HVF** 等硬件加速；开发调试阶段可使用加速，但相关数据不作为评分依据。 |
| 3 | 设备组合：**virtio-gpu-pci、virtio-input、virtio-blk、virtio-net**，以组委会发布基线为准。功能证据统一采用 **QEMU monitor screendump 截图**，主机屏幕录像仅作演示辅助，不作为验收依据。 |

### 1.2 第七节（二）测量规范

| 条款 | 原文 |
|---|---|
| 1 | 初赛性能项评审测量方法与数据规范性，不比较绝对性能结果；性能改善数据以**参赛队伍首个可运行版本（git tag 存档）为基线**。 |
| 2 | 决赛全部性能结果统一主机测量为准…… |
| 3 | 跨层优化的 before/after 数据以队伍首个可运行版本为基线，**提交时存档 git tag 与原始数据，组委会复核存档代码**。 |
| 4 | 测量要求：每项指标**重复不少于 5 次取中位数**，提交**原始数据与波动范围**；提交数据时**注明宿主机 CPU 型号、内存、QEMU 版本与操作系统**，供交叉核验。 |

### 1.3 第八节 参考资料

1. x-kernel 内核基线：https://gitee.com/openkylin/x-kernel
2. Wayland 协议：https://wayland.freedesktop.org/
3. X.Org/X11 参考资料：https://www.x.org/wiki/
4. X.Org 官方文档：https://xorg.freedesktop.org/archive/current/doc/
5. Chromium Ozone 平台资料：https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md

---

## 2. 逐条比对结果（修正前）

「落点」= t490 工作流中承载该条款的文件。「判定」在 §3 修正后给出终值。

| 条款 | 落点 | 修正前判定 |
|---|---|---|
| 七(一)1 架构 | `build_xk_t490.sh:18` `cp platforms/kplat-aarch64/qemu_defconfig .config` ✅ 路径正确 | ⚠️ **无架构断言**（`.config` 被 `.gitignore:46` 忽略，错架构静默可见） |
| 七(一)1 架构（真值） | T490 `~/x-kernel/.config` | ✅ `ARCH="aarch64"` / `MACHINE_AARCH64_QEMU=y` / 无其他 `ARCH_*`；sha256 `42e8d164…` 与基线重展开**逐字节一致** |
| 七(一)2 QEMU 版本 | T490 `~/qemu-root/usr/bin/qemu-system-aarch64` | ✅ **10.2.1** ≥ 8.0；但**无版本断言脚本** |
| 七(一)2 纯 TCG | `run_session_t490.sh` 传 `ACCEL=n` | ✅ 命令行**无任何 `-accel`**、`-cpu cortex-a76`（非 `host`）；宿主无 `/dev/kvm`。⚠️ 但**无法自证**（见下） |
| 七(一)3 四类设备 | xkmake 生成 gpu/blk/net + `--with-input` 补 keybord/mouse | ✅ 五类设备字面齐全 |
| 七(一)3 以基线为准 | `run_session_t490.sh` 传 `VSOCK=n` | ✅ 关掉基线外多余的 `vhost-vsock-pci`（比 `report/14` 记录的调用更干净） |
| 七(一)3 screendump | `run-session.py::screendump()` 周期 `Ctrl-A c` → `screendump` | ✅ 唯一认可的取证方式，已产出 3 张 PPM |
| 七(一)3 完整运行命令 | — | ❌ **`cmd.txt` 不含字面 QEMU 命令行**（D3） |
| 七(二)3 git tag 存档 | `run-session.py::host_fingerprint()` | ❌ **`cwd="."` 导致 git 字段恒空**（D2） |
| 七(二)4 宿主指纹 | `env.txt` | ✅ 有 CPU/内存/QEMU/OS；⚠️ `disk_free` 统计的是**脚本所在分区**而非镜像分区 |
| 参数一致性 | `run_session_t490.sh` / `t490_round.sh` / `README.md` / 手册 4 处各自手写 | ⚠️ **无单一真源**，改一处忘一处即漂移 |
| 第八节 参考资料 | 项目文档 | ⚠️ **未在任何脚本/文档中可追溯地引用**这 5 条 |

---

## 3. 修正内容（6 个文件）

### 3.1 D2（P0）· `env.txt` 的 git 追溯字段恒空 → 已修

**根因**：`scripts/run-session.py` 的 `host_fingerprint()` 用 `subprocess.run(cmd, cwd=".")`。
`cwd="."` 取的是**启动脚本时的当前目录**（T490 上是编排目录 `~/xk6`，**不是 git 仓库**），
git 静默失败、stderr 被丢弃 → 字段为空。

**实测影响面**：25 份历史证据目录中 **20 份**的 `git_commit` 为空
（`_t490-*` 14 份 + `_wsl2-run*` 6 份全部为空；仅 5 份 `_codex-*` 非空）。

```text
修正前（2026-09-21_t490-v7-tty0-shim/env.txt）
  git_describe     :            ← 空
  git_commit       :            ← 空
  disk_free        : 401.0 GiB  ← 统计的是脚本所在分区

修正后（2026-09-21_t490-platverify/env.txt）
  guest_arch       : aarch64  (赛题第七节(一)1 指定，不接受其他架构)
  git_cwd          : /home/mo/x-kernel
  host_vs_guest    : x86_64 != aarch64 （跨架构，硬件加速不可能生效（仍显式 ACCEL=n））
  git_describe     : p0-drm-version-fix-dirty
  git_commit       : 8162e8a51139b52325582bfb8d2095c871954342
  disk_free        : 385.3 GiB (/home/mo/x-kernel)   ← 已指向镜像所在分区
```

**修法**（`run-session.py`）：签名 `host_fingerprint(git_cwd: str = ".")`，
调用改为 `host_fingerprint(cwd)`；git 命令改为 `["git", "-C", git_cwd, …]`；
`disk_free` 改用 `os.statvfs(git_cwd)`。另新增 `guest_arch` / `git_cwd` / `host_vs_guest` 三行。

> **验收判据**（`report/14` C2）：新证据 `env.txt` 的 `git_commit` 非空且 = `8162e8a…` → ✅ 达成。

### 3.2 D3（P1）· `cmd.txt` 缺字面 QEMU 命令行 → 已修

**根因**：`cmd.txt` 只落盘「脚本命令行 + make 命令行 + guest 内命令」，
xkmake 内部生成的 `-device virtio-gpu-pci` / `virtio-blk-pci` / `virtio-net-pci`
与「无 `-accel`」事实**在证据里完全不可见**。

```text
修正前（2026-09-21_t490-v9-shim3/cmd.txt）
  字面 qemu-system-aarch64 行数 : 0
  virtio-keyboard-pci : 1        ← 来自 QEMU_ARGS，字面在 make 命令行里
  virtio-mouse-pci    : 1
  (virtio-gpu-pci / virtio-blk-pci / virtio-net-pci 一个都没有)

修正后（2026-09-21_t490-platverify/cmd.txt）
  字面 qemu-system-aarch64 行数 : 2（多行续行式 + 可粘贴单行式）
  virtio-gpu-pci : 2  virtio-blk-pci : 2  virtio-net-pci : 2
  virtio-keyboard-pci : 3  virtio-mouse-pci : 3
  '-accel' 出现次数 : 0
```

**修法**：新增 `capture_qemu_cmdline()`，在会话**启动前**执行
`make justrun XKMAKE_ARGS=--dry-run <同样的 make 变量>`（`justrun` = `xkmake run --no-build`，
配 `--dry-run` **只打印、不启动 QEMU**），从输出里截取 `qemu-system-aarch64` 起、至首个非续行止的整段。
`cmd.txt` 在**会话开始前**就先落一盘（会话中途崩溃也不丢），结束时重写一次；
新增的 ③/③b 段落同时给出多行续行式与单行可粘贴式。

> 可用 `--skip-cmdline-capture` 关闭；若 `make_args` 已含 `XKMAKE_ARGS` 则自动跳过以避免冲突。

### 3.3 新增 `scripts/t490/platform.env` —— 平台参数单一真源

把第七节(一)1/2/3 + (二) 的全部取值收敛为一组变量，并在文件头写明**条款追溯**：

| 变量 | 值 | 对应条款 |
|---|---|---|
| `PLAT_ARCH` / `PLAT_HAL` | `aarch64` / `kplat-aarch64` | 七(一)1 |
| `PLAT_DEFCONFIG` | `platforms/kplat-aarch64/qemu_defconfig` | 七(一)1（★ 非 README 的失效路径） |
| `PLAT_QEMU_MIN_MAJOR` | `8` | 七(一)2 |
| `PLAT_ACCEL` | `n` | 七(一)2（纯 TCG） |
| `PLAT_CPU_TCG` | `cortex-a76` | 七(一)2（`host` 只在 `accel.is_some()` 时出现） |
| `PLAT_GRAPHIC` / `PLAT_MEM` / `PLAT_SMP` / `PLAT_VSOCK` | `y` / `4g` / `4` / `n` | 七(一)1/3、第六节 |
| `PLAT_INPUT_DEVICES` | `virtio-keyboard-pci virtio-mouse-pci` | 七(一)3 virtio-input |
| `PLAT_REQUIRED_DEVICES` | 5 类 virtio 字面形态 | 七(一)3（机器断言用） |
| `PLAT_REPEAT_MIN` / `PLAT_STAT` | `5` / `median` | 七(二)4 |
| `PLAT_REF_*`（5 条） | 第八节 5 条链接 | 第八节 |
| `PLAT_MAKE_ARGS` / `PLAT_QEMU_ARGS` | 派生 | — |

### 3.4 新增 `scripts/t490/t490_platform_check.sh` —— 35 项合规预检

把第七节每一条变成一条可执行断言，逐条打 `[PASS]/[FAIL]/[WARN]`，末尾给总判定与退出码
（`0` = `PLATFORM_COMPLIANT`）。**全程只读**，唯一副作用是在 `mktemp` 目录里重展开一次基线配置
（`defconfig` 输出路径硬编码为「相对 cwd 的 `.config`」，必须隔离在临时目录）。
产物可直接归档为证据目录里的 `platform-check.txt`。

**关键设计**：
- 架构断言组：`ARCH="aarch64"`、`MACHINE_AARCH64_QEMU=y`、GPU/INPUT/BUS_PCI 均 `=y`、
  **不得**混入 `ARCH_{RISCV64,X86_64,LOONGARCH64}=y` / `RK3588` / `KFEAT_VMM`。
- **正向一致性**：用组委会基线在临时目录重展开，与线上 `.config` **逐字节比对**
  （不能直接 diff 两个文件——基线是 55 行最小种子，线上是展开后的 116 行）。
- QEMU 版本 ≥ 8.0；宿主 `/dev/kvm` 存在时给 WARN（提醒必须显式关加速）。
- 干跑抓字面命令行后，逐条断言：无 `-accel`、`-cpu cortex-a76`、`-machine virt,gic-version=3`、
  `-m 4g`、`-smp 4`、5 类 virtio 设备、`-serial mon:stdio`、无 `-nographic`、`-vga none`。
- git 追溯：打印 `git_commit` / `git_describe`；`-dirty` 给 WARN（对应第七节(二)3 的存档要求）。
- 末尾列出第八节 5 条参考资料。

### 3.5 `scripts/t490/run_session_t490.sh` —— 接上真源与门禁

QEMU 参数不再手写，改为 `source platform.env` 后用 `$PLAT_MAKE_ARGS` /
`--input-devices "$PLAT_INPUT_DEVICES"`；起会话前先跑预检并把 `platform-check.txt`
写进**本轮证据目录**；预检 FAIL 默认阻断（`PLAT_ALLOW_NONCOMPLIANT=1` 可放行）。
新增 `--require-platform-compliance`，让 `run-session.py` 对**实跑命令行**再断言一次。

### 3.6 `scripts/t490/build_xk_t490.sh` —— 补架构断言

`cp` 加失败检查，并在 `make defconfig` 后立即断言 5 个符号 + 排除其他架构。
**为什么必须**：`.config` 被 `.gitignore:46` 忽略 → 架构错误在 git 层面完全不可见；
且 `Makefile:216-218` 的 `defconfig` 只检查 `.config` 是否存在，
`cp` 一旦失败就会在**残留的旧 `.config`** 上原地重展开（幂等、不报错）→ 可能静默构建出另一个架构。

### 3.7 新增 `run-session.py::check_platform_compliance()` —— 实跑命令行断言

会话启动前对抓到的字面命令行做 15 项断言，落盘 `platform-compliance.txt`，
并把结论写进 `manifest.txt` 的「赛题第七节 平台合规」段。

> **实现陷阱（已规避）**：xkmake 会给含逗号/冒号的值加**单引号**
> （`-machine 'virt,gic-version=3'`、`-serial 'mon:stdio'`）。
> 断言前必须先去掉引号，否则会产生**假 FAIL** —— 首版实现即踩此坑，已修正为
> `norm = flat.replace("'", "").replace('"', "")` 后再比对。

---

## 4. 实机验证（T490，2026-09-21 21:23–21:27）

### 4.1 平台合规预检

```bash
bash ~/xk6/scripts/t490/t490_platform_check.sh /tmp/platform-check-verify.txt
# → 判定：PASS=35  FAIL=0  WARN=1 ；PLATFORM_COMPLIANT ；CHECK_RC=0
```

抓取到的字面命令行（预检实跑）：

```text
qemu-system-aarch64
  -m 4g
  -smp 4
  -cpu cortex-a76
  -machine 'virt,gic-version=3'
  -kernel /home/mo/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin
  -device 'virtio-blk-pci,drive=disk0'
  -drive 'id=disk0,if=none,format=raw,file=/home/mo/x-kernel/disk.img'
  -device 'virtio-net-pci,netdev=net0'
  -netdev 'user,id=net0,hostfwd=tcp::61005-:5555,hostfwd=udp::61005-:5555'
  -device virtio-gpu-pci
  -vga none
  -serial 'mon:stdio'
  -object 'rng-random,id=host_rng0'
  -device 'virtio-rng-pci,rng=host_rng0'
  -device virtio-keyboard-pci
  -device virtio-mouse-pci
```

唯一的 WARN：`p0-drm-version-fix-dirty` —— 工作区 dirty，对应第七节(二)3「采数前须 commit/tag」。

### 4.2 一轮真会话（验证证据链修复）

```bash
cd ~/xk6 && BASE_IMG=$HOME/x-kernel/images/pkg-installed.img \
  PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh platverify 150 60 autorun_probe.sh
# ROUND_RC=0
```

证据目录 `~/xk6/evidence/2026-09-21_t490-platverify/`（已回收至本地同名目录）：

| 文件 | 结果 |
|---|---|
| `platform-check.txt` | 预检 `PASS=35 FAIL=0 WARN=1` |
| `platform-compliance.txt` | 实跑命令行断言 **`PASS=15 FAIL=0` → `PLATFORM_COMPLIANT`** |
| `env.txt` | `git_commit=8162e8a5…`、`git_describe=p0-drm-version-fix-dirty`、`disk_free=385.3 GiB (/home/mo/x-kernel)` ✅ |
| `cmd.txt` | 字面 `qemu-system-aarch64` 行 **2**；5 类 virtio 设备齐；`-accel` 出现 **0** 次 ✅ |
| `manifest.txt` | 含「赛题第七节 平台合规」段，`platform_check : PASS=15 FAIL=0 -> PLATFORM_COMPLIANT` |
| `console.log` | 57 433 B 带时间戳串口 + QEMU 全量输出 |
| `screenshots/` | 3 张 monitor screendump（`shot-01-at0045s` / `shot-02-at0105s` / `shot-03-final`） |
| `timestamps.csv` | 截图时间戳 |

### 4.3 三方命令行对照（说明"裸 `make run` 不合规"）

| 项 | 裸 `make run` | 本轮合规调用 | 判定 |
|---|---|---|---|
| `-m` | **`1g`** | `4g` | 裸调不合规（跑 Chromium 会 OOM） |
| `virtio-gpu-pci` | ❌ 缺失 | ✅ | `GRAPHIC ?= n` |
| `-serial mon:stdio` | ❌ 缺失 | ✅ | 只在 `--graphic` 分支追加 |
| `-nographic` | ✅ 存在 | ❌ 不存在 | — |
| `virtio-input` | ❌ 缺失 | ✅ keyboard + mouse | xkmake 工具链**永不**添加 |
| `vhost-vsock-pci` | ✅ 存在 | ❌ 不存在（`VSOCK=n`） | 关掉基线外多余设备 |
| `-accel` | 无 | **无** | 两者都纯 TCG；合规调用显式 `ACCEL=n` 更可自证 |

---

## 5. 交付物清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `scripts/t490/platform.env` | **新增** | 平台参数单一真源（七(一)1/2/3 + 七(二) + 第八节链接） |
| `scripts/t490/t490_platform_check.sh` | **新增** | 35 项合规预检，产出 `platform-check.txt` |
| `scripts/run-session.py` | 修改 | `host_fingerprint(git_cwd)` 修 git 字段；新增 `capture_qemu_cmdline()` / `check_platform_compliance()` / `write_cmd_txt()`；新 CLI `--require-platform-compliance` / `--skip-cmdline-capture`；docstring 补产物说明 |
| `scripts/t490/run_session_t490.sh` | 修改 | 接 `platform.env`；起会话前跑预检；`--require-platform-compliance` |
| `scripts/t490/build_xk_t490.sh` | 修改 | `cp` 失败检查 + `make defconfig` 后架构断言 |
| `scripts/t490/README.md` | 修改 | 新增「§0 平台合规基线」追溯矩阵 + 用法 + 第八节参考资料表；目录分组表补两行；§5 工作流补 ⓪ 预检 |
| `evidence/2026-09-21_t490-platverify/` | **新增** | 本轮验证证据（8 文件 + 3 张 screendump） |
| 本文件 `report/15` | **新增** | 逐条比对 + 修正 + 验证记录 |

> 本地与 T490 两侧脚本已 `md5sum` 比对一致。

---

## 6. 残留风险与下一步

| # | 事项 | 严重度 | 建议 |
|---|---|---|---|
| R1 | T490 工作区 `-dirty`（P0–P4 补丁未提交）→ 第七节(二)3 要求 before/after 数据「存档 git tag，组委会复核存档代码」 | **P0** | **采数前先 commit + 打 tag**（首个可运行版本 = before 基线），让 `bundle.toml` 的 `git-dirty = "false"` |
| R2 | 历史 20 份证据目录的 `git_commit` 为空，无法回溯 | P1 | 无需回填；在文档里注明「2026-09-21 21:24 之后的证据才带 git 追溯字段」 |
| R3 | 第七节(二)4 要求「每项指标 ≥5 次取中位数 + 波动范围」，目前**无聚合脚本** | P1 | 待补：从多轮 `console.log`/`timestamps.csv` 提取指标并算 median + range 的脚本（性能项 15 分里的「数据统计规范 3 分」） |
| R4 | `generate` 预检的 `t490_platform_check.sh` 单次约 30–60 s（含 cargo 调 xconf + xkmake 干跑） | 低 | 迭代时可只在改内核/换 QEMU 后跑；日常 `run_session_t490.sh` 已自动串联 |
| R5 | 上游 README 的失效 defconfig 路径（5 文件 17 行） | 低 | 已在 fork `mofan0810/x-kernel` 的分支 `fix-doc-defconfig-path`（commit `0a0f2a2`）修好；上游 issue/PR 未提 |

---

## 7. 一句话总结

t490 的 **QEMU 命令行本身一直是合规的**（`-m 4g` / `virtio-gpu-pci` / `virtio-input` / `-serial mon:stdio` /
无 `-accel` / `-cpu cortex-a76`），真正缺的是**「可自证」**——
`env.txt` 的 git 追溯字段恒空、`cmd.txt` 里看不到四类设备与"无加速"。
本轮把第七节逐条变成 **35 + 15 条机器断言**、把散落 4 处的参数收敛为**单一真源 `platform.env`**，
并给 `build_xk_t490.sh` 补上架构断言，随后在 T490 上**实机跑通验证**（预检 `FAIL=0`，
证据目录 8 文件齐备、`cmd.txt` 5 类设备可见、`-accel` 0 次）。
**下一步**：先落 R1（commit + tag 首个可运行版本），再继续 G17（crashpad `SCM_CREDENTIALS`）主攻。

---

*配套阅读：`report/14-平台合规核验-AArch64-QEMU基线.md`（首次核验与 C1–C7 修正清单）、
`report/13-Chromium-renderer追击-P3之后的第二层阻塞.md`（当前技术阻塞）、
`docs/赛题六-基础任务操作手册.md`（S1–S7 操作步骤）*
