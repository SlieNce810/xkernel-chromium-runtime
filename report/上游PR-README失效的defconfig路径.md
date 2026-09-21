# 上游 PR 草稿：修正 README 与 docs 中失效的平台 defconfig 路径

> **状态**：草稿 —— **尚未提交**（fork 上已有可用的 head 分支）
> **目标仓库**：`https://gitee.com/openkylin/x-kernel`（base = `main`）
> **head**：`https://gitee.com/mofan0810/x-kernel` → 分支 `fix-doc-defconfig-path`
> **head commit**：`0a0f2a2e2b9e1e1cc3d6fb90d11def889d22e04f`
> **base commit（探测时 main）**：`eb5f3a360a8b6d77c10dba0be30bc4cf1f8de229`（2026-09-21）
> **发现日期**：2026-09-21
> **性质**：纯文档缺陷（**零代码、零行为变更**）
> **建议 label**：`文档` / `缺陷`

---

## 〇、提交前必须先知道的 3 件事

1. **上游 `docs/ai/skills/pr-ci-review/SKILL.md` 明确要求**：PR 正文要写清 *what changed / why / expected behavior*，
   因为 **AI review 的「Description」维度**按此打分。→ 本文 §一 的正文已按此组织，**不要删掉 §7「预期行为」**。
2. **不要夹带内核补丁**。本 PR 只改文档。P0–P4 的内核补丁受众/排期与本文完全不同，混在一起会被 review 打回。
3. **不要声称"某个 commit 引入的回归"**。本次核查基于**浅克隆**（`git rev-parse --is-shallow-repository` → `true`），
   结论一律以 **main 现状 + HTTP 探测**为准。

---

## 一、PR 正文（可直接粘贴为 body）

### 建议标题

```
docs: correct stale platform defconfig paths in README and docs
```

> 备选（更短）：`docs: fix dead platforms/<arch>-qemu-virt/defconfig path in README and docs`
>
> 上游提交规范是 `!<MR号> <type>(<scope>): <subject>`，**MR 号由平台分配**，
> 创建时先不写 `!NNN`，合并前由维护者/MR 流程补。

---

### ——— 以下为 body 正文开始 ———

#### What changed

修正 `README.md`、`README_CN.md` 与 `docs/` 下的 **17 行**失效平台 defconfig 路径。
文档教的 `platforms/<arch>-qemu-virt/defconfig` **已不存在**，正确路径是
`platforms/kplat-<arch>/qemu_defconfig`。

#### Why

按 `README.md` 第 2 节「Config kernel」照抄会直接失败：

```bash
$ cp platforms/aarch64-qemu-virt/defconfig .config
cp: cannot stat 'platforms/aarch64-qemu-virt/defconfig': No such file or directory
```

**而这个失败是静默的，会放大成"静默构错架构"**：

1. `Makefile` 的 `defconfig` 目标只检查 `.config` **是否存在**，不检查来源
   （`Makefile:216-218`：`test -f .config || { echo "error: copy a platform defconfig ..."; exit 1; }`）；
2. `.config` 被 `.gitignore:46` 忽略；
3. 于是 `cp` 失败 → `.config` 未被替换 → `make defconfig` 照常在**残留的旧 `.config`** 上原地展开（幂等成功）
   → 若旧 `.config` 属于另一个架构，**构建静默切到别的架构，且 `git status` 完全看不出来**。

路径探测（直接对上游 main 取 raw，不依赖本地克隆）：

| 文档中写的路径 | HTTP | 是否存在 |
|---|---|---|
| `platforms/aarch64-qemu-virt/defconfig` | **404** | ❌ |
| `platforms/x86_64-qemu-virt/defconfig` | **404** | ❌ |
| `platforms/riscv64-qemu-virt/defconfig` | **404** | ❌ |
| `platforms/kplat-aarch64/qemu_defconfig` | **200** | ✅ |
| `platforms/kplat-x86_64/qemu_defconfig` | **200** | ✅ |

`platforms/` 现状：

```text
platforms/                 → kplat  kplat-aarch64  kplat-loongarch64  kplat-macros  kplat-riscv64  kplat-x86_64
platforms/kplat-aarch64/   → qemu_crosvm_defconfig  qemu_defconfig  qemu_virtcca_defconfig  rk3588_defconfig
platforms/kplat-x86_64/    → qemu_csv_defconfig  qemu_defconfig
```

#### Root cause

代码重命名后文档未同步。`xtask/xconfig/src/cli/gen_cargo.rs::resolve_plat_name()` 的注释（main 现状）：

```rust
// The arch HAL crate (kplat-<arch>) is derived from ARCH. There is no longer
// a separate PLATFORM symbol: PLATFORM_KPLAT_<ARCH> was a redundant 1:1 echo
// of ARCH and has been removed; the crate is now selected by ARCH directly.
```

即 HAL crate 已由 `<arch>-qemu-virt` 一类旧名统一为 `kplat-<arch>`，
`platforms/` 下的目录名与之同步，**文档未同步**。

`platforms/` 是两处不一致的共同源头，因此本次同时修正**平台名列表**：

- `xtask/xkmake/src/qemu.rs:143-174` 的 match 臂是
  `"kplat-aarch64" | "kplat-riscv64" | "kplat-loongarch64" | "kplat-x86_64"`
  → 文档里标为"XKMake supports QEMU boot for"的 `*-qemu-virt` 列表与代码不符，属实质性错误（不只是路径死链）。
- 仓库内部本就自洽的另一半证据：`.githooks/pre-commit:46` 用的就是
  `cp platforms/<plat>/qemu_defconfig .config`；`AGENTS.md:102`、
  `docs/container-architecture.md:1026`、`docs/ai/skills/code-guidelines/concurrency.md:63`、
  `docs/ai/skills/problem-diagnosis/references/basic-tools.md:34`、
  `docs/ai/skills/performance-analysis/references/lock-stat.md:22`、
  `mm/page_table/docs/security.md:234`、`task/ktimer-core/docs/design.md:286`
  也已是正确路径。本 PR 让其余文档与"唯一事实来源"对齐。

#### Changes（5 文件 / +17 −17）

| 文件 | 行 | 原内容 → 修正为 |
|---|---|---|
| `README.md` | 46、106 | `cp platforms/aarch64-qemu-virt/defconfig .config` → `cp platforms/kplat-aarch64/qemu_defconfig .config` |
| `README.md` | 110 | `cp platforms/x86_64-qemu-virt/defconfig .config` → `cp platforms/kplat-x86_64/qemu_defconfig .config` |
| `README_CN.md` | 44、104 | 同 `README.md` 46、106 |
| `README_CN.md` | 108 | 同 `README.md` 110 |
| `docs/releases/v0.1.0-2606.md` | 59 | aarch64 同上 |
| `docs/ai/skills/build-workflow/SKILL.md` | 54 | aarch64 同上 |
| `docs/ai/skills/build-workflow/SKILL.md` | 162–165 | 平台名列表 4 行：`aarch64-qemu-virt` / `riscv64-qemu-virt` / `loongarch64-qemu-virt` / `x86_64-qemu-virt` → `kplat-aarch64` / `kplat-riscv64` / `kplat-loongarch64` / `kplat-x86_64` |
| `docs/xkmake-design.md` | 145 | aarch64 同上 |
| `docs/xkmake-design.md` | 290–293 | 平台名列表 4 行，同上 |

全部失效位置应这样检索（**只查 `qemu-virt/defconfig` 会漏掉两个平台名列表**）：

```bash
grep -rn "qemu-virt" README.md README_CN.md docs/
```

#### Verification

1. **路径存在性自校验**：把改动后 5 个文件里出现的所有 `platforms/...` 路径逐个 `test -e` →
   7 条全部 `OK`，无 `MISSING`。
2. **平台名与代码一致性**：`kplat-aarch64|kplat-riscv64|kplat-loongarch64|kplat-x86_64`
   4 个名字**目录存在**且 `xtask/xkmake/src/qemu.rs` 中**各有 1 条 match 臂**。
3. **残留检查**：`grep -rn "qemu-virt" README.md README_CN.md docs/` **无匹配**。
4. **未触及其它内容**：`git diff --stat` = `5 files changed, 17 insertions(+), 17 deletions(-)`，**无 `.rs`、无配置、无脚本改动**。

#### Expected behavior（修改后）

- 照抄 `README.md` / `README_CN.md` 的 quick start，`cp platforms/kplat-aarch64/qemu_defconfig .config`
  **成功**；其后 `make defconfig` 展开的是 **AArch64** 配置，`grep -q '^ARCH="aarch64"' .config` 成立。
- `docs/ai/skills/build-workflow/SKILL.md:51-56` 的命令可直接执行，按该 skill 走的自动化流程不再在第一步失败。
- `docs/xkmake-design.md` 与 `docs/ai/skills/build-workflow/SKILL.md` 中"QEMU 支持平台"列表
  与 `xtask/xkmake/src/qemu.rs` 的 match 臂**逐字一致**。
- 除上列字符串外**无任何行为变化**：`make defconfig` 的语义、错误信息、CI 行为均不变。

#### Scope / Risk

- **纯文档**：不涉及内核代码、Kconfig、构建脚本、CI 配置。
- **零运行时风险**：不改变任何符号、接口或默认值；不存在"文档改动导致 CI 行为变化"的路径。
- **`ENABLE_DOC_CHECK` 不受影响**：该 Jenkins 参数控制的是 *Rust 文档生成检查*（默认 `false`），
  与本次 markdown 路径修正无关。
- **不夹带**：本 PR **不包含**任何内核补丁诉求（DRM / unix-socket SCM_RIGHTS / sched / netlink /
  prctl / madvise 等均另行走 issue + 排期），以保持"文档改动可立即合入"的特性。

#### Deliberately untouched

`xtask/xconfig/tests/fixtures/conditional_defaults/Kconfig:29` 含字符串
`default "qemu-virt" if ARCH_AARCH64`，但它是**测试夹具数据**（用于验证条件默认值解析），
**不是路径**，改动它会破坏测试语义 → 本 PR 刻意保留。
（因此"全仓库 zero-hit"不是本 PR 的目标，目标是"路径与平台名列表 zero-hit"。）

#### Optional follow-ups（不在本 PR 范围，供维护者参考）

1. `README` 的 defconfig 小节可补一句：*若 `cp` 失败，请勿继续执行 `make defconfig`*；
2. 或让 `make defconfig` 在展开后断言 `ARCH` 与所选平台目录自洽（当前无此校验，
   是"静默构错架构"得以成立的根因）；
3. 或把 defconfig 路径收敛为**单一事实来源**（例如提供 `make <plat>_defconfig` 目标），
   避免同一条路径散落在 5 个文件里 —— 与仓库中「整理 X-Kernel 编码规范唯一事实来源并接入 Review 流程」
   的思路一致。

#### How to reproduce the defect on current main

```bash
# 1) 文档里写的路径（期望失败）
ls -l platforms/aarch64-qemu-virt/defconfig
# → ls: cannot access 'platforms/aarch64-qemu-virt/defconfig': No such file or directory

# 2) 直接对上游 main 探测（无需克隆）
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

# 3) 文档中全部失效位置（含平台名列表）
grep -rn "qemu-virt" README.md README_CN.md docs/

# 4) 确认 .config 被忽略（静默失败的成因）
git check-ignore -v .config        # → .gitignore:46:.config
```

#### Environment

| 项 | 值 |
|---|---|
| 宿主 CPU | Intel(R) Core(TM) i7-8665U @ 1.90GHz |
| 内存 | 14.7 GiB |
| 操作系统 | Ubuntu 26.04 LTS（Linux 7.0.0-31-generic x86_64） |
| QEMU | 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.2) |
| guest 平台 | `kplat-aarch64` + 组委会 `qemu_defconfig`，纯 TCG |
| 克隆深度 | **浅克隆**（`--is-shallow-repository` → `true`）→ 不判断引入 commit |

### ——— body 正文结束 ———

---

## 二、怎么把它提上去

**前提**：head 分支已在 fork 上（`fix-doc-defconfig-path` @ `0a0f2a2`）。

> **正文文件已备好**：`tmp/pr-body.md`（= §一 的 body，可直接喂 `--body-file`，免手工复制粘贴）。

### 方式 A：Gitee 网页（最省事）

1. 打开 Gitee 自动给出的入口：

   ```
   https://gitee.com/mofan0810/x-kernel/pull/new/mofan0810:fix-doc-defconfig-path...mofan0810:main
   ```

2. **把 base 仓库改成 `openkylin/x-kernel`、base 分支 `main`**（默认会指向自己的 fork，必须改，
   否则提成了 fork 内部的 MR）。
3. 标题、正文填 §一 的内容 → 创建。

### 方式 B：`ge` CLI（上游 skill 里给的方式）

```bash
ge pr create --title "docs: correct stale platform defconfig paths in README and docs" \
  --body-file tmp/pr-body.md \
  --head fix-doc-defconfig-path --base main
```

> `ge` 是上游环境里已认证的 Gitee v5 API 包装（该 skill 记为 `luodeb` 身份）；
> 本机若不装 `ge`，用方式 A 或下面的原始 API。

### 方式 C：Gitee v5 API

```bash
curl -sk -X POST "https://gitee.com/api/v5/repos/openkylin/x-kernel/pulls" \
  -d "access_token=$GITEE_TOKEN" \
  -d "title=docs: correct stale platform defconfig paths in README and docs" \
  -d "head=fix-doc-defconfig-path" \
  -d "base=main" \
  -d "body=$(cat tmp/pr-body.md)"
```

---

## 三、可选：先提 issue 再提 PR？

Gitee 惯例支持在正文写 `Fixes #I...` 关联 issue，但**不强制**。当前有两条路：

| 方案 | 优点 | 代价 |
|---|---|---|
| **只提 PR**（推荐） | 改动极小且自证完整（404/200 对照表就是全部证据），review 可直接看 diff | issue 区没有独立记录 |
| **先提 issue 再提 PR** | 补丁 25 分素材更完整；issue 可独立留痕 | 多一轮往返；且上游已查过 main 前 100 条 issue 无同主题，不必先占位 |

issue 正文草稿已备：`report/上游issue-README失效的defconfig路径.md`（含"提交前自检"表）。

---

## 四、提上去之后会自动发生什么

按上游 `docs/ai/skills/pr-ci-review/SKILL.md`：

1. Gitee webhook 触发 Jenkins `x-kernel-ci-test`（构建流水线）；
2. Jenkins `ai-review` 把 `## AI Code Review Summary` 发到 PR 评论区（用户 `x-cibot`）；
3. CI 状态由 `openkylin-cibot` 回帖（标记 `<!-- x-kernel-ci -->`）。

查最新状态 / 读 review 意见（**匿名即可读**）：

```bash
PR=<PR号>
# CI 结果评论 + AI review 结论
curl -sk "https://gitee.com/api/v5/repos/openkylin/x-kernel/pulls/$PR/comments?per_page=100&sort=id&order=desc"
# 最新 Jenkins 构建（按 Gitee PR 触发原因过滤）
curl -sk "https://jenkins.openkylin.top/job/x-kernel-ci-test/api/json?tree=builds%5Bnumber,result,url,actions%5Bcauses%5BshortDescription%5D%5D%5D"
```

> ⚠️ Jenkins 控制类动作（stop / rerun）需要账号 + CSRF crumb，**不要被动去试**（上游 skill Rule 3）。
> Jenkins 只保留最近 **31** 次构建（Rule 4）。

---

## 五、提交前自检

| 项 | 状态 |
|---|---|
| head 分支已推送且远端 ref 与本地一致 | ✅ `0a0f2a2`（`git ls-remote` 已核对） |
| 改动范围仅文档 | ✅ `git diff --stat` 无 `.rs` / 配置 / 脚本 |
| 目标仓库/分支是否选对 | ⏳ **提 PR 时手动确认 base = `openkylin/x-kernel:main`** |
| 是否夹带内核补丁 | ❌ 未夹带 |
| 是否声称历史回归 | ❌ 未声称（浅克隆，已显式声明） |
| 是否含敏感信息 | ✅ 无（无密钥、无内网地址、无队伍身份信息） |
| 是否需要附截图 | 不需要，404/200 对照表 + `ls` 输出即完整证据 |
| AI review 的 Description 维度 | ✅ §What/Why/Expected behavior 齐备 |
| PR 标题前缀 `!<MR号>` | ⏳ 平台分配 MR 号后再补（创建时先不写） |
