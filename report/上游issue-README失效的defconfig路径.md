# 上游 issue 草稿：README 与 docs 中的平台 defconfig 路径已失效

> **状态**：草稿（**未提交任何上游 issue/PR**）
> ✦ **2026-09-21 晚更新**：修复已在 fork `gitee.com/mofan0810/x-kernel` 落地并推送 ——
> 分支 `fix-doc-defconfig-path`、commit `0a0f2a2`（5 文件 / +17 −17，纯文档）。
> 上游 `openkylin/x-kernel` 的 issue / PR 仍待用户决定是否提交。
> 同时**更正了本文的行数计数**：初稿「5 文件 11 行」为漏计（详见下文「全部失效位置」节）。
> **目标仓库**：`https://gitee.com/openkylin/x-kernel`（Issues 区）
> **上游 main 版本**：`eb5f3a360a8b6d77c10dba0be30bc4cf1f8de229`（2026-09-21 用 `git ls-remote` 探测）
> **本地环境**：T490 / Ubuntu 26.04 / QEMU 10.2.1 / x-kernel main 浅克隆
> **发现日期**：2026-09-21
> **性质**：纯文档缺陷（不涉及内核代码）

---

## 一、Issue 正文

### 建议标题

```
文档缺陷：README 与 docs 中的平台 defconfig 路径 platforms/<arch>-qemu-virt/defconfig 已失效（实测 HTTP 404）
```

> 备选（更短）：`README/docs 的平台 defconfig 路径已失效，照抄会导致 cp 静默失败`

建议 Label：`文档` / `缺陷`；里程碑可与 `X-KERNEL 2026.1230` 关联（如适用）。

---

### 1. 现象

按 `README.md` 第 2 节「Config kernel」的指引执行：

```bash
cp platforms/aarch64-qemu-virt/defconfig .config
make defconfig
```

`cp` 直接失败：

```
cp: cannot stat 'platforms/aarch64-qemu-virt/defconfig': No such file or directory
```

**上游 main 路径探测**（直接对 gitee raw 取，不依赖本地克隆）：

| 文档中的路径 | HTTP | 实际是否存在 |
|---|---|---|
| `platforms/aarch64-qemu-virt/defconfig` | **404** | ❌ |
| `platforms/x86_64-qemu-virt/defconfig` | **404** | ❌ |
| `platforms/riscv64-qemu-virt/defconfig` | **404** | ❌ |
| `platforms/kplat-aarch64/qemu_defconfig` | **200** | ✅ |
| `platforms/kplat-x86_64/qemu_defconfig` | **200** | ✅ |

`platforms/` 当前的真实结构：

```
platforms/                  → kplat  kplat-aarch64  kplat-loongarch64  kplat-macros  kplat-riscv64  kplat-x86_64
platforms/kplat-aarch64/    → qemu_crosvm_defconfig  qemu_defconfig  qemu_virtcca_defconfig  rk3588_defconfig
```

即：目录名已统一为 **`kplat-<arch>`**，defconfig 文件名为 **`qemu_defconfig`**；
而文档里保留的是旧命名 `<arch>-qemu-virt` + `defconfig`。

**全部失效位置（5 个文件 / 17 行）**：

| 文件 | 行 | 内容类型 |
|---|---|---|
| `README.md` | 46 | `cp platforms/aarch64-qemu-virt/defconfig .config` |
| `README.md` | 106 | 同上 |
| `README.md` | 110 | `cp platforms/x86_64-qemu-virt/defconfig .config` |
| `README_CN.md` | 44 | `cp platforms/aarch64-qemu-virt/defconfig .config` |
| `README_CN.md` | 104 | 同上 |
| `README_CN.md` | 108 | `cp platforms/x86_64-qemu-virt/defconfig .config` |
| `docs/releases/v0.1.0-2606.md` | 59 | 同上（aarch64） |
| `docs/ai/skills/build-workflow/SKILL.md` | 54 | 同上（aarch64） |
| `docs/ai/skills/build-workflow/SKILL.md` | 162–165 | 平台名列表 `aarch64-qemu-virt;` / `riscv64-…;` / `loongarch64-…;` / `x86_64-….`（**4 行**） |
| `docs/xkmake-design.md` | 145 | 同上（aarch64） |
| `docs/xkmake-design.md` | 290–293 | 平台名列表，同上（**4 行**） |

> **计数口径说明**：初稿记作「5 文件 11 行」，是把两个平台名列表各按 1 行计所致；
> 实际 **9 行 `cp` 命令 + 8 行平台名列表 = 17 行**。
> 因此检索**不能只用** `grep -rn "qemu-virt/defconfig"`——会漏掉整个平台名列表。
> 另有一处 **不可改**：`xtask/xconfig/tests/fixtures/conditional_defaults/Kconfig:29`
> 的 `default "qemu-virt" if ARCH_AARCH64` 是测试夹具数据，不是路径。

检索命令：

```bash
grep -rn "qemu-virt" README.md README_CN.md docs/
```

---

### 2. 根因

属于**代码重命名后文档未同步**。证据是 `xtask/xconfig/src/cli/gen_cargo.rs` 中
`resolve_plat_name()` 的注释（main 现状）：

```rust
fn resolve_plat_name(config: &HashMap<String, String>) -> &'static str {
    // The arch HAL crate (kplat-<arch>) is derived from ARCH. There is no longer
    // a separate PLATFORM symbol: PLATFORM_KPLAT_<ARCH> was a redundant 1:1 echo
    // of ARCH and has been removed; the crate is now selected by ARCH directly.
    if config.get("ARCH_AARCH64") == Some(&"y".to_string()) {
        "kplat-aarch64"
    } else if ...
```

即 HAL crate 已由 `<arch>-qemu-virt` 一类旧名统一改为 `kplat-<arch>`，
`platforms/` 下的目录名与之一致；**README 与 docs 未同步更新**。

> **关于引入时间的说明**：本次核查基于**浅克隆**
> （`git rev-parse --is-shallow-repository` → `true`，仅 2 个 commit），
> 因此**不判断该失效由哪个 commit 引入**，仅以 main 当前状态为准。

---

### 3. 影响面（为什么值得修）

#### 3.1 失败是**静默**的，会造成架构错配

`make defconfig` 只检查 `.config` **是否存在**，不检查它的来源：

```make
# Makefile:216-218
defconfig:
	@test -f .config || { echo "error: copy a platform defconfig to .config first"; exit 1; }
	@$(XCONFIG) defconfig .config --kconfig Kconfig --srctree .
```

而 `.config` 被 `.gitignore` 忽略（`.gitignore:46`）。于是照抄文档的后果是：

```
cp 失败 → .config 未被替换 → make defconfig 照常成功（在残留的旧 .config 上原地展开，幂等）
        → 若旧 .config 属于其他架构，构建静默切到另一个架构，且 git status 完全看不出来
```

`docs/xkmake-design.md:150` 承诺 *"If `.config` does not exist, XKMake fails with an actionable error"*，
但该保护**只在完全没有 `.config` 时生效**，覆盖不到"路径写错"这一最常见情形。

#### 3.2 影响 AI 技能文档

`docs/ai/skills/build-workflow/SKILL.md:54` 含同一失效命令。
任何按该 skill 执行的自动化流程 / Agent 都会在第一步直接失败。

#### 3.3 实际踩坑

本团队在构建 x-kernel 时照抄该指引，`cp` 失败后由 `make defconfig` 静默沿用旧 `.config`，
事后才发现文档路径与仓库结构不符。

---

### 4. 建议修法（仅文档改动，无代码变更）

| 原内容 | 建议改为 |
|---|---|
| `cp platforms/aarch64-qemu-virt/defconfig .config` | `cp platforms/kplat-aarch64/qemu_defconfig .config` |
| `cp platforms/x86_64-qemu-virt/defconfig .config` | `cp platforms/kplat-x86_64/qemu_defconfig .config` |
| 平台名列表中的 `aarch64-qemu-virt` | `kplat-aarch64` |
| 平台名列表中的 `riscv64-qemu-virt` | `kplat-riscv64` |
| 平台名列表中的 `loongarch64-qemu-virt` | `kplat-loongarch64` |
| 平台名列表中的 `x86_64-qemu-virt` | `kplat-x86_64` |

涉及文件：`README.md`、`README_CN.md`、`docs/releases/v0.1.0-2606.md`、
`docs/ai/skills/build-workflow/SKILL.md`、`docs/xkmake-design.md`。

#### 可选加固建议（非本 issue 范围，供维护者参考）

1. 在 `README` 的 defconfig 小节补一句：*若 `cp` 失败请勿继续执行 `make defconfig`*；
2. 或让 `make defconfig` 在展开后断言 `ARCH` 与所选平台目录自洽（当前无此校验）；
3. 或把 defconfig 路径收敛为单一事实来源（例如提供 `make <plat>_defconfig` 目标），
   避免同一条路径散落在 5 个文件里 —— 与仓库中
   「整理 X-Kernel 编码规范唯一事实来源并接入 Review 流程」的思路一致。

---

### 5. 复现

```bash
# 1) 文档里写的路径（期望失败）
ls -l platforms/aarch64-qemu-virt/defconfig
# → ls: cannot access 'platforms/aarch64-qemu-virt/defconfig': No such file or directory

# 2) 直接对上游 main 探测（无需本地克隆）
for p in platforms/aarch64-qemu-virt/defconfig \
         platforms/x86_64-qemu-virt/defconfig \
         platforms/riscv64-qemu-virt/defconfig \
         platforms/kplat-aarch64/qemu_defconfig \
         platforms/kplat-x86_64/qemu_defconfig; do
  printf "%-45s " "$p"
  curl -fsSL --max-time 20 -o /dev/null -w "HTTP %{http_code}\n" \
    "https://gitee.com/openkylin/x-kernel/raw/main/$p" 2>/dev/null || echo "HTTP 404"
done
# → 前三条 404，后两条 200

# 3) 文档中全部失效位置
grep -rn "qemu-virt" README.md README_CN.md docs/

# 4) 确认 .config 被忽略（静默失败的成因）
git check-ignore -v .config        # → .gitignore:46:.config
```

---

### 6. 环境

| 项 | 值 |
|---|---|
| 宿主 CPU | Intel(R) Core(TM) i7-8665U @ 1.90GHz |
| 内存 | 14.7 GiB |
| 操作系统 | Ubuntu 26.04 LTS（Linux 7.0.0-31-generic x86_64） |
| QEMU | 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.2) |
| guest 平台 | `kplat-aarch64` + 组委会 `qemu_defconfig`，纯 TCG |

---

## 二、提交前自检（不进 issue 正文）

| 项 | 状态 |
|---|---|
| 是否与已有 issue 重复 | ✅ 已查 main 前 100 条 issue，无同主题（含「整理…唯一事实来源」条，属相关但不同） |
| 是否声称了历史回归 | ❌ 未声称 —— 浅克隆无法判断，已显式声明 |
| 是否含敏感信息 | ✅ 无（无密钥、无内网地址、无队伍身份信息） |
| 是否需要附日志/截图 | 不需要，路径 404/200 对照表即为完整证据 |
| 是否夹带内核补丁诉求 | ❌ 不夹带 —— 本条是纯文档 issue，与 P0–P4 内核补丁分开提 |

> **纪律提醒**：这是**独立的一条文档缺陷**，不要把 P1–P4 的补丁诉求塞进这个 issue。
> 两者受众与 review 路径不同：文档改动可立即合入，内核补丁需要排期。
