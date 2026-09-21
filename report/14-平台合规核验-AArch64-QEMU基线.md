# 14 · 平台合规核验：AArch64 QEMU 基线

> **核验日期**：2026-09-21 20:39–20:50（GMT+8）
> **核验对象**：T490（`mo@10.249.63.140`）上的 `~/x-kernel`
> **核验依据**：赛题第七节（一）统一评测平台 1/2/3 条
> **核验方式**：全程只读（`--dry-run` + `/proc` + 临时目录重生成），未修改 T490 上任何文件
> **结论一句话**：**三项判据全部通过**；但**上游 README（main 分支现状）给出的 defconfig 路径已失效**
> （`cp` 必然失败，实测 HTTP 404），另发现 **2 处证据链缺陷**（`git_commit` 恒空、`cmd.txt` 不含字面 QEMU 命令行）。

---

## 0. 结论先行

| # | 核验项 | 判据 | 结果 |
|---|---|---|---|
| 1 | `.config` 与组委会 `qemu_defconfig` 基线一致性 | 用原始基线在临时目录重新展开，逐字节比对 | ✅ **sha256 完全一致** |
| 2 | `make run` 实际启动的 QEMU 机型与参数 | 活进程 `/proc/<pid>/cmdline` | ✅ **AArch64 `virt` 平台 + 纯 TCG** |
| 3 | 构建输出目标架构 | `file` / ELF 头 / target 目录 / bundle 元数据 | ✅ **aarch64-unknown-none-softfloat** |

**但命令本身有 1 处错误、工程上有 2 处缺陷**（均不改变上述结论，但影响可复现性与证据效力）：

| # | 问题 | 严重度 | 位置 |
|---|---|---|---|
| D1 | `cp platforms/aarch64-qemu-virt/defconfig .config` —— **该路径不存在**（上游 README 原文即错） | **P0** | 上游 `README.md` / `README_CN.md` 等 **5 文件 17 处** |
| D2 | `env.txt` 的 `git_describe` / `git_commit` **恒为空** → 违反第七节(二)3「存档 git tag」 | **P0** | `scripts/run-session.py:281` |
| D3 | `cmd.txt` 只记 `make` 命令，**不含字面 `qemu-system-aarch64 …` 行** | P1 | `scripts/run-session.py:493-500` |

---

## 1. 核验项 1 · `.config` 与基线一致性

### 1.1 发现：**上游 README 给出的 defconfig 路径已失效**（main 分支现状）

命令 `cp platforms/aarch64-qemu-virt/defconfig .config` 直接抄自 x-kernel 官方 README，
但**该路径不存在**：

```bash
$ ls -ld ~/x-kernel/platforms/aarch64-qemu-virt
ls: cannot access 'platforms/aarch64-qemu-virt': No such file or directory
```

**上游 main 实测**（直接打 gitee raw，不依赖本地克隆）：

| 路径 | 上游 main HTTP | 结论 |
|---|---|---|
| `platforms/aarch64-qemu-virt/defconfig` | **404** | README 写的，不存在 |
| `platforms/x86_64-qemu-virt/defconfig` | **404** | README 写的，不存在 |
| `platforms/riscv64-qemu-virt/defconfig` | **404** | README 写的，不存在 |
| `platforms/kplat-aarch64/qemu_defconfig` | **200** | ← 真实存在（组委会基线） |
| `platforms/kplat-x86_64/qemu_defconfig` | **200** | ← 真实存在 |

**受影响的文档位置（5 个文件 / 17 行，全部写的是失效路径）**：

| 文件 | 行号 |
|---|---|
| `README.md` | 46、106、110 |
| `README_CN.md` | 44、104、108 |
| `docs/releases/v0.1.0-2606.md` | 59 |
| `docs/ai/skills/build-workflow/SKILL.md` | 54、162–165 |
| `docs/xkmake-design.md` | 145、290–293 |

> **计数更正（2026-09-21 晚，全仓库复核时发现）**：本节初稿记作「5 文件 9 处」，
> 把两个**平台名列表**各按 1 行计。实测两个列表各占 **4 行**（`aarch64/riscv64/loongarch64/x86_64`），
> 故实际是 **9 行 `cp` 命令 + 8 行平台名列表 = 17 行**。
> 正确计数命令（含平台名列表，不能只 `grep 'qemu-virt/defconfig'`）：
> `grep -rn "qemu-virt" README.md README_CN.md docs/`
> 唯一需排除的是 `xtask/xconfig/tests/fixtures/conditional_defaults/Kconfig:29`
> （`default "qemu-virt" if ARCH_AARCH64`，是测试夹具数据，不是路径，**不可改**）。

`platforms/` 的真实内容与 defconfig 变体：

```
platforms/            → kplat  kplat-aarch64  kplat-loongarch64  kplat-macros  kplat-riscv64  kplat-x86_64
platforms/kplat-aarch64/ → qemu_crosvm_defconfig  qemu_defconfig  qemu_virtcca_defconfig  rk3588_defconfig
```

> **成因**：命名体系改过。`xtask/xconfig/src/cli/gen_cargo.rs:105-110` 的注释写明 ——
> 「The arch HAL crate (`kplat-<arch>`) is derived from ARCH. There is no longer a separate
> PLATFORM symbol…」即 HAL crate 由 `aarch64-qemu-virt` 一类旧名统一改成 `kplat-<arch>`，
> **代码改了，README 与 docs 没同步**。
>
> ⚠️ 本地是**浅克隆**（`git rev-parse --is-shallow-repository` → `true`，`.git/shallow` 存在，
> 只有 2 个 commit），**无法从本地历史判断"何时改的"** —— 本节结论一律以上游 main 的 HTTP 探测为准。

> **正确命令**：`cp platforms/kplat-aarch64/qemu_defconfig .config`
> （组委会手册 S2 用的正是这条，与基线一致）

**失败模式（关键）**：`cp` 失败后 `.config` **不被覆盖**，而 `make defconfig` 只检查文件是否存在：

```make
# Makefile:216-218
defconfig:
	@test -f .config || { echo "error: copy a platform defconfig to .config first"; exit 1; }
	@$(XCONFIG) defconfig .config --kconfig Kconfig --srctree .
```

```rust
// xtask/xconfig/src/cli/defconfig.rs:38-39  —— 输出路径硬编码，与输入无关
let output = PathBuf::from(".config");
let generated = defconfig_to_output(defconfig, output.clone(), kconfig, srctree)?;
```

**后果链**：`cp` 失败 → `.config` 未被替换 → `make defconfig` 在**残留的旧 `.config`** 上原地重展开
（幂等，不报错）→ 若残留的是 riscv/loongarch/x86 的配置，**构建会静默切到另一个架构**。
即：README 这条命令的失效在当前这台机器上"没出事"，纯属因为残留的 `.config` 恰好是对的。

**放大风险**：`.config` 被 git 忽略，架构错误在版本控制层面完全不可见。

```
$ git check-ignore -v .config
.gitignore:46:.config	.config
```

### 1.2 严格一致性验证（正向证明）

把**原始基线**放到临时工作目录重新展开（`defconfig` 输出固定落在 cwd，故隔离在 `/tmp` 内，零副作用）：

```bash
mkdir -p /tmp/xkcheck && cp platforms/kplat-aarch64/qemu_defconfig /tmp/xkcheck/seed_defconfig
cd /tmp/xkcheck
xconf defconfig /tmp/xkcheck/seed_defconfig --kconfig $R/Kconfig --srctree $R
```

比对结果：

| 文件 | 结果 | 大小 |
|---|---|---|
| `.config` | ✅ **BYTE-IDENTICAL** | 3006 B / 116 行 |
| `auto.conf` | ✅ **BYTE-IDENTICAL** | 1430 B |
| `autoconf.h` | ✅ **BYTE-IDENTICAL** | 2001 B |

```text
sha256(.config 线上)              = 42e8d16450352712d78813b5f78b7ca221dfb88fadc796f57ecf317d7e33f669
sha256(.config 由基线重生成)       = 42e8d16450352712d78813b5f78b7ca221dfb88fadc796f57ecf317d7e33f669
sha256(platforms/kplat-aarch64/qemu_defconfig) = 951ecf869456cd8f273aaa2fcdb02b5083e4d1fd373ed2ba24202c20297700f2
```

> **为何后两者不等**：基线 `qemu_defconfig` 是 **54 行的最小种子**；线上 `.config` 是它在 Kconfig 上
> **展开 116 行**后的完整形态（defaults、`# X is not set`、derived 值全部materialize）。
> 两者不等价才是正常的——所以核验方法必须是"重展开后比对"，不能直接 diff 两个文件。

### 1.3 关键架构项确认

| 符号 | 线上 `.config` | 基线要求 | 判定 |
|---|---|---|---|
| `ARCH` | `"aarch64"` | aarch64 | ✅ |
| `ARCH_AARCH64` | `=y` | y | ✅ |
| `ARCH_RISCV64` / `ARCH_X86_64` / `ARCH_LOONGARCH64` | 均 `is not set` | 均不选 | ✅ |
| `MACHINE` | `"qemu"` | qemu | ✅ |
| `MACHINE_AARCH64_QEMU` | `=y` | y | ✅ |
| `MACHINE_AARCH64_RK3588` | `is not set` | 不选 | ✅ |
| `MACHINE_RISCV64_QEMU` / `MACHINE_X86_64_QEMU` / `MACHINE_LOONGARCH64_QEMU` | 均 `is not set` | 均不选 | ✅ |
| `KFEAT_VMM` | `is not set` | 不选 | ✅（决定 `-machine` 取值） |
| `KFEAT_VIRTIO_BUS_PCI` | `=y` | y | ✅（决定 `-pci` 后缀） |
| `KFEAT_DRIVER_VIRTIO_GPU` / `_INPUT` | 均 `=y` | 均 y | ✅ |
| `NR_CPUS` | `4` | 与 `SMP=4` 匹配 | ✅ |

> 两处"看着不同、其实相同"的写法（**不是偏差**）：
> `BOOT_CONSOLE_ADDR=0x9000000` ≡ 基线 `0x09000000`；`RTC_PADDR=0x9010000` ≡ 基线 `0x09010000`。
> 仅前导零差异。

**唯一"差异"**：线上 `.config` 缺少基线里的一行注释
`# Weston graphics requires the virtio GPU and input drivers.` —— 注释不入配置，无影响。

---

## 2. 核验项 2 · QEMU 机型与参数

核验时 T490 上**正有一个 QEMU 会话在跑**（pid `286028`，启动于 `2026-09-21 20:46:18`），
直接取活进程命令行作为最强证据：

```text
qemu-system-aarch64 -m 4g -smp 4 -cpu cortex-a76 -machine virt,gic-version=3 \
  -kernel /home/mo/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file=/home/mo/x-kernel/disk.img \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::61005-:5555,hostfwd=udp::61005-:5555 \
  -device virtio-gpu-pci -vga none -serial mon:stdio \
  -object rng-random,id=host_rng0 -device virtio-rng-pci,rng=host_rng0 \
  -device virtio-keyboard-pci -device virtio-mouse-pci
```

### 2.1 逐项对照

| 赛题要求 | 实际 | 判定 |
|---|---|---|
| `qemu-system-aarch64` ≥ 8.0 | **10.2.1** (Debian 1:10.2.1+ds-1ubuntu3.2)，`~/qemu-root/usr/bin/` | ✅ |
| AArch64 虚拟平台机型 | `-machine virt,gic-version=3` | ✅ |
| 纯 TCG，禁 KVM/HVF | 命令行**无任何 `-accel`**；`-cpu cortex-a76`（非 `host`） | ✅ |
| `virtio-gpu-pci` | ✅ 存在 | ✅ |
| `virtio-input` | `virtio-keyboard-pci` + `virtio-mouse-pci`（经 `QEMU_ARGS` 显式追加） | ✅ |
| `virtio-blk` | `virtio-blk-pci` | ✅ |
| `virtio-net` | `virtio-net-pci` | ✅ |
| screendump 取证通路 | `-serial mon:stdio` → `Ctrl-A c` → `screendump` | ✅ |

### 2.2 纯 TCG 的三重独立证明

1. **命令行无 `-accel`**（唯一硬判据）。
2. **`-cpu cortex-a76`**：`qemu.rs:149-153` 里 `cpu = if accel.is_some() { "host" } else { "cortex-a76" }`
   —— 出现 `cortex-a76` 即说明 `accel == None`，是**软件模拟**。
3. **宿主根本没有 `/dev/kvm`**，且进程 fd 表里无 KVM 句柄：

```bash
$ ls -l /dev/kvm
ls: cannot access '/dev/kvm': No such file or directory
$ ls -l /proc/286028/fd | grep -i kvm     # 无输出
```

> 补充：`Makefile:106` 在 Linux 上 `ACCEL ?= y` 是**默认加速**，但 `qemu.rs:104-121` 的
> `hardware_accel()` 要求「宿主架构 == guest 架构 且 非 WSL 且 `/dev/kvm` 存在」。
> 本机 x86_64 宿主跑 aarch64 guest —— 第一条就不满足，**天然返回 None**。
> 即：即使不传 `ACCEL=n` 也拿不到加速。**但提交时仍应显式写 `ACCEL=n`**，让判据一眼可见。

### 2.3 ⚠️ 裸 `make run` 不等于合规启动

用 `--dry-run` 抓取**用户描述的裸 `make run`** 实际下发内容：

```text
qemu-system-aarch64 -m 1g -smp 4 -cpu cortex-a76 -machine virt,gic-version=3 \
  -kernel …/kernel.bin \
  -device virtio-blk-pci,drive=disk0 -drive … \
  -device virtio-net-pci,netdev=net0 -netdev … \
  -device vhost-vsock-pci,… -object rng-random,… -device virtio-rng-pci,… \
  -nographic
```

与合规版本的差异：

| 项 | 裸 `make run` | 合规调用 | 原因 |
|---|---|---|---|
| `virtio-gpu-pci` | ❌ 缺失 | ✅ | `qemu.rs:484` `needs_graphic = … VIRTIO_GPU && args.graphic`；`GRAPHIC ?= n` |
| `virtio-input` | ❌ 缺失 | ✅ | `qemu.rs` 全文件 `grep -cE 'input\|keyboard\|mouse\|tablet'` = **0**，工具链永不添加 |
| `-serial mon:stdio` | ❌ 缺失 | ✅ | 仅在 `--graphic` 分支追加（`qemu.rs:541`） |
| 显示模式 | `-nographic` | 图形窗口 | 非 graphic 时追加（`qemu.rs:51-52`） |
| 内存 | **`-m 1g`** | `-m 4g` | `MEM ?=` 为空 → xkmake 默认 1g |

> **结论**：`make run` 裸调用**不构成合规启动**（缺 2 类设备、缺 monitor 取证通路、内存过小）。
> 合规调用（即 20:46 那个进程所用的）：
>
> ```bash
> make run GRAPHIC=y ACCEL=n MEM=4g SMP=4 \
>   QEMU_ARGS='-device virtio-keyboard-pci -device virtio-mouse-pci'
> ```
>
> **注意**：用户消息里描述的是裸 `make run`，但 20:46 实际在跑的进程是**合规版本**。
> 两者不一致 —— 请确认当前实际使用的是自己手敲的命令还是 `scripts/t490/*.sh` 编排脚本。

---

## 3. 核验项 3 · 构建输出架构

| 判据 | 结果 |
|---|---|
| 内核镜像类型 | `kernel.bin: Linux kernel ARM64 boot executable Image, little-endian, 4K pages` ✅ |
| 内核 ELF | `kernel.elf: ELF 64-bit LSB executable, ARM aarch64, version 1 (GNU/Linux), statically linked, with debug_info, not stripped` ✅ |
| target 目录 | `target/` 下**架构目录只有** `aarch64-unknown-none-softfloat` ✅（无 x86_64 / riscv64 / loongarch64 残留） |
| 构建元数据 | `bundle.toml`: `arch = "aarch64"`, `platform = "kplat-aarch64"`, `target = "aarch64-unknown-none-softfloat"`, `build-mode = "release"`, `nr-cpus-max = 4`, `vmm-enabled = false` ✅ |
| 工具链 | `rust-toolchain.toml` → `1.95.0`，targets 含 `aarch64-unknown-none-softfloat` ✅ |

`bundle.toml` 里的追溯字段（**可直接用于提交材料**）：

```toml
build-id     = "2b3ff9a5f855c0f6477f6d7039d339e243790778aca1a47ee5231498cf68408f"
config-sha256 = "128e17a1045d6b541ebf71c0f031f4a1d879f0622e3334ea343df486dded6a83"
git-commit   = "8162e8a51139b52325582bfb8d2095c871954342"
git-dirty    = "true"
build-time   = "2026-09-21T11:44:12.806933475Z"
build-machine = "mo@mo-ThinkPad-T490"
```

> **别被两个 sha256 搞混**：`bundle.toml` 的 `config-sha256=128e17a1…` 是**配置语义哈希**，
> 与 `.config` 的**文件哈希** `42e8d164…` 不同源，两者不同属正常。
>
> `git-dirty = "true"` 是正常的（工作区有 P0–P4 未提交补丁）；但提交材料时必须**先提交/打 tag**
> 再采数，否则复核用的存档代码与实测二进制不一致。

---

## 4. 新发现的 2 处证据链缺陷

### D2（P0）· `env.txt` 的 git 追溯字段恒为空

实测全部证据目录（含 `_t490-p4`、`_t490-nnp`、当前 `_basic-render-x11`）：

```
git_describe     :        ← 空
git_commit       :        ← 空
```

**根因**（`scripts/run-session.py:278-284`）：

```python
for cmd, label in ((["git", "describe", "--tags", "--always", "--dirty"], "git_describe"),
                   (["git", "rev-parse", "HEAD"], "git_commit")):
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=10, cwd=".")   # ← BUG
```

`cwd="."` 取的是**启动脚本时的当前目录**（本机通常是项目根，或 T490 上的 `~/xk6` —— 两者都不是 git 仓库；
实测 `git -C ~/xk6 rev-parse --show-toplevel` → `fatal: 不是 Git 仓库`），而**不是** `--cwd` 指向的 x-kernel 仓库。
`git` 在非仓库目录静默失败（stderr 被丢弃、只读 stdout），于是字段为空。

对比 `~/x-kernel` 里 git 信息其实是齐的：

```
$ git -C ~/x-kernel describe --tags --dirty
p0-drm-version-fix-dirty
$ git -C ~/x-kernel rev-parse HEAD
8162e8a51139b52325582bfb8d2095c871954342
```

**影响**：直接违反第七节(二)3「提交时存档 git tag 与原始数据，组委会复核存档代码」。
before/after 数据**无法回溯到 commit**，这正是性能项最容易被扣分的点。

**修法**（3 处，一处变量名）：

```python
# 1) 函数签名加参数
-def host_fingerprint() -> list[str]:
+def host_fingerprint(git_cwd: str = ".") -> list[str]:

# 2) git 命令改成显式指定仓库目录（保持 tuple 结构不变）
-            out = subprocess.run(cmd, capture_output=True, text=True, timeout=10, cwd=".")
+            out = subprocess.run(["git", "-C", git_cwd, *cmd[1:]],
+                                 capture_output=True, text=True, timeout=10)

# 3) 调用点传入已解析的 cwd（在 main() 里，第 374 行）
-    fp = host_fingerprint()
+    fp = host_fingerprint(cwd)
```

> 同源小问题（P2）：`disk_free` 用的是 `os.statvfs(".")` / `disk_usage(".")`（第 286/292 行），
> 统计的是**脚本所在分区**而非**存放 QEMU 镜像的 x-kernel 分区**。建议一并改为 `git_cwd`。

### D3（P1）· `cmd.txt` 不含字面 QEMU 命令行

实测 `cmd.txt` 只落盘 3 段内容（脚本命令行 / `make` 命令 / guest 内命令），
**没有** `--dry-run` 打印的 `qemu-system-aarch64 …` 字面行。后果：

```bash
$ grep -oE 'virtio-(gpu|blk|net|keyboard|mouse)-pci' 2026-09-21_t490-p4/cmd.txt | sort | uniq -c
      1 virtio-keyboard-pci      ← 来自 QEMU_ARGS，字面在 make 命令里
      1 virtio-mouse-pci
                                ← virtio-gpu-pci / virtio-blk-pci / virtio-net-pci 一个都没有
```

评委若按第七节(一)3 核对"四类设备齐备"，从 `cmd.txt` 里**只能看到 2 类**。
同理"无 `-accel`"这条也只能间接从 `ACCEL=n` 推断，而非直接看到。

**修法**：在 `cmd.txt` 落盘时追加一次 dry-run 输出（`--no-build`，不产生副作用）：

```bash
cd "$XKERNEL_DIR" && make justrun XKMAKE_ARGS=--dry-run $(MAKE_ARGS) >> "$OUT/cmd.txt" 2>&1
```

如此 `cmd.txt` 里就同时有「人敲的命令」和「机器实际执行的命令」，合规性自证闭环。

---

## 5. 修正清单

| ID | 优先级 | 修正 | 验收判据 |
|---|---|---|---|
| **C1** | **P0** | 构建命令用 `cp platforms/kplat-aarch64/qemu_defconfig .config`（**不要照抄 README**），并在 `make defconfig` 后**立即断言架构** | `grep -q '^ARCH="aarch64"' .config` 且 `grep -q '^MACHINE_AARCH64_QEMU=y' .config` |
| **C2** | **P0** | 修 `run-session.py` 的 `cwd="."` → `git -C <--cwd>` | 新一轮证据的 `env.txt` 里 `git_commit` 非空且等于 `8162e8a…` |
| **C3** | P1 | 提交前**先 commit / 打 tag** 再采数 | `git status --short` 中内核源码无未提交修改；`bundle.toml` 的 `git-dirty = "false"` |
| **C4** | P1 | `cmd.txt` 追加 `--dry-run` 字面命令行 | `cmd.txt` 里 `grep -c 'virtio-gpu-pci'` ≥ 1，且 `grep -cE '\-accel (kvm\|hvf)'` = 0 |
| **C5** | P2 | 统一显式写 `ACCEL=n`（即使本机天然无加速） | 命令行含 `--no-accel`（xkmake 层）；QEMU 层无 `-accel` |
| **C6** | P2 | 统一显式写 `MEM=4g SMP=4`，避免落到默认 `-m 1g` | 命令行含 `-m 4g`（`-m 1g` 跑 Chromium 会 OOM） |
| **C7** | P2 | 向上游提 **docs 修正**（README.md / README_CN.md / docs 共 9 处失效路径） | 改动只碰文档、零风险、易合入，是"上游协作"的可见产出 |

> **C7 的写法建议**：单独提一个 `docs:` 前缀的 PR（不要混进 P1–P4 的内核补丁里）。
> 正文给出「路径 404 vs 200」的对照表 + `gen_cargo.rs:105-110` 那句命名变更注释作为依据即可。
> 注意本地是浅克隆，**别声称"某 commit 引入的回归"** —— 只看 main 现状。

**C1 建议的落地写法**（可直接粘进shell 或编排脚本）：

```bash
set -euo pipefail
cd ~/x-kernel

cp platforms/kplat-aarch64/qemu_defconfig .config
make defconfig

# 架构断言：.config 被 gitignore，光靠 git status 看不出架构错误
grep -q '^ARCH="aarch64"'            .config || { echo "FATAL: ARCH 不是 aarch64"; exit 1; }
grep -q '^MACHINE_AARCH64_QEMU=y'    .config || { echo "FATAL: 不是 AArch64 QEMU 机型"; exit 1; }
! grep -q '^ARCH_\(RISCV64\|X86_64\|LOONGARCH64\)=y' .config || { echo "FATAL: 混入其他架构"; exit 1; }
echo "OK: .config 为 kplat-aarch64 基线"
```

---

## 6. 复现命令（本次核验所用，全部只读）

```bash
# ── 核验项 1：路径与配置一致性 ──
ls -1 ~/x-kernel/platforms/
ls -ld ~/x-kernel/platforms/aarch64-qemu-virt          # 期望：No such file or directory
git -C ~/x-kernel check-ignore -v .config              # 期望：.gitignore:46:.config

# 上游 main 路径探测（README 写的是 404，正确路径是 200）—— C7 的取证命令
for p in platforms/aarch64-qemu-virt/defconfig platforms/kplat-aarch64/qemu_defconfig; do
  printf "%-45s " "$p"
  curl -fsSL --max-time 20 -o /dev/null -w "HTTP %{http_code}\n" \
    "https://gitee.com/openkylin/x-kernel/raw/main/$p" 2>/dev/null || echo "HTTP 404"
done
# README 里失效路径的全部出现位置
grep -rn "qemu-virt/defconfig" ~/x-kernel --include="*.md" | grep -v "^.*target/"

R=/home/mo/x-kernel
rm -rf /tmp/xkcheck && mkdir -p /tmp/xkcheck
cp $R/platforms/kplat-aarch64/qemu_defconfig /tmp/xkcheck/seed_defconfig
cd /tmp/xkcheck && xconf defconfig /tmp/xkcheck/seed_defconfig --kconfig $R/Kconfig --srctree $R
cmp /tmp/xkcheck/.config $R/.config && echo BYTE-IDENTICAL
cmp /tmp/xkcheck/auto.conf $R/auto.conf && echo BYTE-IDENTICAL
cmp /tmp/xkcheck/autoconf.h $R/autoconf.h && echo BYTE-IDENTICAL

# ── 核验项 2：QEMU 机型与参数 ──
P=$(pgrep -f 'qemu-syste[m]'); tr '\0' ' ' < /proc/$P/cmdline; echo
ls -l /proc/$P/fd | grep -i kvm          # 期望：无输出
ls -l /dev/kvm                           # 本机：No such file or directory
~/qemu-root/usr/bin/qemu-system-aarch64 --version

# 对比裸 make run 与合规调用（无副作用）
cd ~/x-kernel
make justrun XKMAKE_ARGS=--dry-run
make justrun XKMAKE_ARGS=--dry-run GRAPHIC=y ACCEL=n MEM=4g SMP=4 \
     QEMU_ARGS='-device virtio-keyboard-pci -device virtio-mouse-pci'

# ── 核验项 3：产物架构 ──
file $R/target/xkmake/kplat-aarch64/release/kernel.bin
file $R/target/xkmake/kplat-aarch64/release/kernel.elf
ls -1 $R/target/
grep -E 'arch|platform|target|git-|vmm' $R/target/xkmake/kplat-aarch64/release/bundle.toml
```

> ⚠️ **不要用 `pkill -f <pattern>`**：会匹配到承载它的 ssh shell 自身。
> 需要时用字符类规避，如 `pkill -f "qemu-syste[m]"`。
> 本次核验**未**终止任何进程 —— 20:46 启动的那个会话仍在运行。

---

## 7. 本次采集的宿主机指纹（可直接填进提交材料）

| 项 | 值 |
|---|---|
| CPU | Intel(R) Core(TM) i7-8665U CPU @ 1.90GHz |
| 逻辑核 | 8 |
| 内存 | 14.7 GiB |
| 操作系统 | Ubuntu 26.04 LTS |
| 内核 | Linux 7.0.0-31-generic x86_64 |
| 磁盘可用 | 385.9 GiB |
| QEMU | QEMU emulator version 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.2) |
| 宿主架构 | x86_64（≠ guest，故无硬件加速可能） |
| `/dev/kvm` | **不存在** |

---

## 8. 一句话总结

平台合规性**三项全过**——`.config` 与组委会基线 sha256 级一致、实际运行时是 AArch64 `virt` 纯 TCG（无 `-accel`、无 `/dev/kvm`、`-cpu cortex-a76`）、产物是 `aarch64-unknown-none-softfloat`。
但**上游 README 教的命令已经失效**（`platforms/aarch64-qemu-virt/defconfig` 实测 404，正确是 `platforms/kplat-aarch64/qemu_defconfig`），
照抄只会撞上"`cp` 静默失败 → 用残留 `.config`"，只是因为残留文件恰好正确才没出事；且证据链有两处硬缺陷
（`git_commit` 恒空、`cmd.txt` 缺字面命令行），**这两条会直接打到第七节(二)3 的复核要求上**。
建议在下一轮跑测前先落 C1/C2（**均为一行级改动**），并考虑把 C7 作为独立 docs PR 提给上游。

---

*配套阅读：`report/07-合规核对与测量规范.md`（条款矩阵与测量协议）、`report/13-Chromium-renderer追击-P3之后的第二层阻塞.md`（当前技术阻塞）*
