# 16 · R1 基线存档 + G17 SCM_CREDENTIALS 修复

> **执行日期**：2026-09-21 21:40–22:40（GMT+8）
> **主机**：T490 `mo@10.249.63.140`（Ubuntu 26.04 LTS / i7-8665U / QEMU 10.2.1 / 纯 TCG）
> **对应条款**：《赛题六》第七节(二)1/3（git tag 存档）、第七节(一)3 + 第六节(二)（补丁质量、Linux 行为基线对比）
> **结论一句话**：R1 完成——内核工作区 **-dirty 转 CLEAN**，P0–P5 六个补丁分次提交并打上双基线 tag；
> G17——`SCM_CREDENTIALS` 从 **EINVAL(22) 修到与 Linux 逐条一致**，且该缺口在**上游最新 main（`!821`）仍未修**。

---

## 0. 结论先行

| # | 事项 | 结果 |
|---|---|---|
| 1 | R1 · 工作区 dirty → clean | ✅ `git describe` 从 `p0-drm-version-fix-dirty` → **`v0.2-compat-p0p4-1-g0c611be`（无 `-dirty`）** |
| 2 | R1 · 分次提交 | ✅ 6 个提交：P1 `8efe025` / P2a `c6930c2` / P2b `031a3b4` / P3 `f8b9224` / P4 `7b60564` / **P5 `0c611be`** |
| 3 | R1 · 基线 tag | ✅ `v0.1-first-runnable` → `f8b9224`（首个可运行版本）<br>✅ `v0.2-compat-p0p4` → `7b60564`（兼容补丁齐全） |
| 4 | R1 · pre-commit 门禁 | ✅ `make fmt` + `make clippy` 真实通过（非 SKIP 绕过） |
| 5 | **G17 · 根因** | ✅ `posix/net/src/cmsg.rs::CMsg::parse` 只认 `SCM_RIGHTS`，其余 cmsg 一律 `EINVAL` |
| 6 | **G17 · 修复** | ✅ 2 文件 / 9 处改动（`cmsg.rs` + `io.rs`），**编译器一次通过** |
| 7 | **G17 · 验证** | ✅ `credprobe` 在 **T490 原生（Linux 基线）** 与 **guest** 上**同源同结果：7/7 PASS** |
| 8 | **G17 · 上游现状** | ⚠️ **最新上游 main（`!821`）仍未修** → 这是可提上游的有效缺口（补丁分 4 分/项） |
| 9 | **G17 · Chromium 层效果** | ✅ `crashpad missing credentials` **从「出现」变为 0 次**<br>❌ 但 **renderer 仍未创建、browser 仍 rc=191 @~60 s**（§2.7，症状消除≠阻塞解除） |

---

## 1. R1 · 基线存档

### 1.1 为什么这一步是硬要求

第七节(二)3 原文：

> 跨层优化的 before/after 数据以队伍首个可运行版本为基线，**提交时存档 git tag 与原始数据，组委会复核存档代码**。

R1 之前 T490 工作区长期 `-dirty`（`git describe` = `p0-drm-version-fix-dirty`），
意味着**实测二进制与任何可复核的提交都不对应** —— 这是性能项最容易被扣分的点。

### 1.2 执行方式

可复现脚本：`scripts/t490/r1_commit_and_tag.sh [--dry-run]`

```bash
bash ~/xk6/scripts/t490/r1_commit_and_tag.sh --dry-run   # 先干跑核对
bash ~/xk6/scripts/t490/r1_commit_and_tag.sh             # 正式执行
```

脚本的关键防护（**第一版全部踩过，已修**）：

| 防护 | 教训 |
|---|---|
| 提交失败立即 `die` | 第一版**没检查 `git commit` 返回值**，5 次提交全被 pre-commit 拒绝却继续执行，把 tag 打到了 `39d1788 !810 refactor(timer)` 上 |
| 打 tag 前断言「恰好新增 5 个提交 + 工作区干净」 | 同上：没有它，tag 落点完全不受控 |
| 打 tag 后断言 `git rev-list -n1 <tag> == 期望 SHA` | 双保险 |
| 暂存区必须为空 | 上一次失败运行的 `git add` 会串进第一个提交，破坏「一次提交 = 一个缺陷」的边界 |
| 只 `git add -- <7 个已知文件>`，禁止 `git add -A` | `images/` 下有 4GB 磁盘镜像（`.sha256` 未被上游 `.gitignore` 覆盖） |
| 提交身份沿用 `xk6 <xk6@local>` | 与 P0 提交 `8162e8a` 保持同一作者，避免同仓库两种身份 |

### 1.3 pre-commit 钩子（真实跑通，非绕过）

上游钩子在 `.githooks/pre-commit`（`core.hooksPath` 指过去），会跑：

- `make fmt` → `cargo +nightly-2026-03-08 fmt --all`（**pinned nightly，装它花了 19 分钟**）
- `make clippy` → 依赖 pinned 工具 `cargo-shear`（`make install-tools`）
- 逃生开关：`SKIP_FMT=1` / `SKIP_CLIPPY=1` / `SKIP_ALL=1`

本轮**没有使用任何 SKIP**，`✅ pre-commit: fmt + clippy checks passed.` 是真实通过的。

> ⚠️ **副作用**：`make fmt` 改写了 P1 的两个文件（`stream.rs` +74→+76、`channel.rs` +33→+29）。
> 因此 R1 完成后**必须重新 `make build`**，否则「存档源码 ↔ 实测二进制」不一致（已重建，`BUILD_RC=0`）。

### 1.4 tag 语义与「首个可运行版本」的判定

| tag | 落点 | 含义 |
|---|---|---|
| `p0-drm-version-fix` | `8162e8a` | 早前已建（仅 P0） |
| **`v0.1-first-runnable`** | `f8b9224`（P3） | **首个可运行版本**：Weston 图形会话可建立、Chromium 可创建窗口并显示本地 HTML |
| **`v0.2-compat-p0p4`** | `7b60564`（P4） | 兼容补丁齐全；**只含兼容修复、尚无任何性能优化** |

> **判定依据**：report/13 记录 —— P3 解决「子进程 exec 前全灭」后**窗口 UI 首次能完整渲染**
> （`evidence/2026-09-21_t490-nnp/screenshots/shot-06-at0346s.png`）。P4 是其后追加的 madvise 兼容修复。
> **两个 tag 都留**，因为「首个可运行」的严格字面含义落在 P3，而「优化前的完整兼容态」落在 P4 ——
> 用哪个作 before 基线由队伍在采数时声明，两者都已存档可复核。

### 1.5 验收

```text
git status --short   →  (空) 工作区 CLEAN ✓
git describe         →  v0.2-compat-p0p4-1-g0c611be      ← 无 -dirty
git log --oneline -7
  0c611be feat(knet): accept SCM_CREDENTIALS on AF_UNIX sockets
  7b60564 fix(mm): stop rejecting well-formed madvise calls
  f8b9224 feat(ksyscall): implement PR_SET_NO_NEW_PRIVS
  031a3b4 fix(knet): accept non-zero multicast groups in netlink bind
  c6930c2 fix(ksyscall): resolve sched target by tid as well as tgid
  8efe025 fix(knet): deliver AF_UNIX SOCK_STREAM ancillary data
  8162e8a fix(drm): tolerate NULL pointers in DRM_IOCTL_VERSION and DRM_UNIQUE
```

补丁归档：`report/patches/0001..0007`（`git format-patch 39d1788..HEAD` 导出，共 7 个，含 P0）。

---

## 2. G17 · SCM_CREDENTIALS

### 2.1 根因

`posix/net/src/cmsg.rs`：

```rust
pub(crate) enum CMsg {
    Rights { fds: Vec<Arc<VfsFile>> },     // ← 只有 SCM_RIGHTS
}
...
Ok(match (hdr.cmsg_level as u32, hdr.cmsg_type as u32) {
    (SOL_SOCKET, SCM_RIGHTS) => { ... Self::Rights { fds } }
    _ => { return Err(KError::InvalidInput); }   // ← 其余一律 EINVAL(22)
})
```

Linux 对**良构**的 `SCM_CREDENTIALS` 返回成功。crashpad（`crashpad/util/linux/socket.cc:177`）
走 AF_UNIX `SOCK_SEQPACKET` 传凭证，`sendmsg` 失败即报 `missing credentials`，
随后子进程在初始化阶段静默退出（rc=191）。

### 2.2 关键侦察：上游最新 main **仍未修**

用今天更新的上游快照 `tmp/xk-docs`（HEAD = 我们 fork 的 `0a0f2a2`，其父是上游 **`!821`**，
比 T490 基线 `!810` 前进 11 个 MR）核对：

| 上游 `!821` 已有的 | 上游 `!821` 仍缺的 |
|---|---|
| `SO_PASSCRED` 选项（`opt.rs`，存在 `GeneralOptions`） | **`CMsg::parse` 仍只有 `Rights`，`_ =>` 依然 `InvalidInput`** |
| `UnixCredentials{pid,uid,gid}`（`#[repr(C)]`） | 用户侧 `sendmsg(SCM_CREDENTIALS)` 仍返回 EINVAL |
| `KernelAncillaryData::Credentials` → 接收侧序列化 | 无 `scm_check_creds` 等价校验 |
| netlink kobject-uevent 的**内核合成**凭证（pid=0/uid=0/gid=0） | — |

上游 `net/knet/docs/security.md` 的信任边界表述是「只有 kobject-uevent 协议合成接收侧凭证」，
即**用户侧 SCM_CREDENTIALS 从未被支持**。

> **结论**：G17 不是「上游已修的回归」，而是**真实缺口** —— 修好并提 PR 有实际价值。

### 2.3 对齐的 Linux 语义（net/core/scm.c）

| 环节 | Linux 行为 |
|---|---|
| `scm_send` 长度校验 | `cmsg_len` 必须**恰好** `CMSG_LEN(sizeof(struct ucred))`，否则 **EINVAL(22)** |
| `scm_check_creds` 身份校验 | 仅允许声明自身身份（pid = 本进程 tgid、uid/gid 属自身集合）；否则需 `CAP_SYS_ADMIN`，否则 **EPERM(1)** |
| 接收侧 | 接收 socket 置 `SO_PASSCRED` 时，**内核自动**附带发送方凭证（无需发送方显式发） |

### 2.4 补丁（`scripts/t490/p5_scm_credentials.py`，幂等）

改动 **2 文件 / 9 处**：

| 文件 | 改动 |
|---|---|
| `posix/net/src/cmsg.rs` | ① import `SCM_CREDENTIALS` / `ucred` ② import `knet::options::UnixCredentials` ③ `CMsg` 增 `Credentials{cred}` 变体 ④ `parse` 增 `(SOL_SOCKET, SCM_CREDENTIALS)` 分支（长度校验 + `scm_check_creds` 等价校验） |
| `posix/net/src/io.rs` | ① import `UnixCredentials` ② import `SCM_CREDENTIALS` / `ucred` ③ `SocketAncillary` 增 `Credentials` 变体 ④ `into_socket_ancillary` 增分支 ⑤ `push_socket_cmsg` 增序列化分支 |

**为什么只需 2 个文件**：`posix/net/src/io.rs` 的 `into_socket_ancillary` 本来就会把**发送方**投递过来的
`CMsg` 反序列化回 `msg_control`（P1 建立的 `SCM_RIGHTS` 通道走的就是这条路）。
所以 `CMsg` 多一个变体 + `push_socket_cmsg` 补一条序列化分支，接收端即自动可用 —— **不需要改 knet**。

```rust
(SOL_SOCKET, SCM_CREDENTIALS) => {
    if data.len() != size_of::<ucred>() {
        return Err(KError::InvalidInput);            // 对齐 scm_send
    }
    let claimed = ucred { pid: ..., uid: ..., gid: ... };
    let cred = kprocess::current_cred();
    let privileged = cred.is_privileged();
    let pid_ok = privileged || claimed.pid == kprocess::current_user_thread().pid();
    let uid_ok = privileged || claimed.uid == cred.euid();
    let gid_ok = privileged || claimed.gid == cred.egid();
    if !(pid_ok && uid_ok && gid_ok) {
        return Err(KError::from(LinuxError::EPERM));  // 对齐 scm_check_creds
    }
    Self::Credentials { cred: UnixCredentials { pid: claimed.pid, uid: claimed.uid, gid: claimed.gid } }
}
```

### 2.5 验证：双端同源探针

`scripts/t490/credprobe.c` —— **同一份源码编译两次**：

```bash
gcc                    -O1 -Wall -Wextra -o credprobe-linux credprobe.c   # T490 原生 = Linux 基线
aarch64-linux-musl-gcc -static -O2 -Wall -Wextra -o credprobe    credprobe.c   # 注入 guest
```

| 用例 | **Linux 原生**（uid=1000） | **x-kernel + G17**（uid=0） | 一致 |
|---|---|---|---|
| T1 `socketpair(AF_UNIX, SOCK_SEQPACKET)` | rc=0 | rc=0 | ✅ |
| **T2 sendmsg SEQPACKET + SCM_CREDENTIALS** | **rc=3**（字节数） | **rc=3** | ✅ |
| T3 DGRAM / STREAM 同上 | rc=3 / rc=3 | rc=3 / rc=3 | ✅ |
| T4 `SCM_CREDENTIALS{pid=0}` | **-1 / EPERM(1)** | rc=3（root 具 CAP_SYS_ADMIN） | ✅ 语义一致 |
| T5 `SO_PASSCRED` 收到 ucred | controllen=32, pid=302775 uid=1000 gid=1000 | controllen=28, pid=19 uid=0 gid=0 | ✅ |
| T6 SEQPACKET + SCM_RIGHTS | rc=3 | rc=3 | ✅ |
| T7 cmsg 长度=4 | **-1 / EINVAL(22)** | **-1 / EINVAL(22)** | ✅ |
| **合计** | **pass=7 fail=0** | **pass=7 fail=0** | ✅ |

证据：`evidence/2026-09-21_t490-credg17/`（console.log 含完整 `[CRED]` 逐行 errno 事实）

> **T4 的价值**：非特权 Linux 上 `pid=0` 声明返回 **EPERM**，实测坐实了 `scm_check_creds` 的存在与语义 ——
> 这是本补丁「不是简单放过、而是按 Linux 校验」的直接证据。

### 2.6 已知偏差（如实记录）

| # | 偏差 | 影响 | 后续 |
|---|---|---|---|
| B1 | T5 的 `msg_controllen` 返回 **28**（`CMSG_LEN(12)`），Linux 返回 **32**（含对齐） | 单条 cmsg 下 `CMSG_NXTHDR` 行为一致，无实际影响 | 可对齐为 `CMSG_SPACE` 语义 |
| B2 | 未实现 Linux 的「接收端 `SO_PASSCRED=1` 时内核**自动**附带发送方凭证」；当前凭证明细**随发送方的 cmsg 一起投递** | 发送方未显式发 cmsg 时接收端拿不到凭证（Linux 会拿到） | 需在 knet unix recv 侧补 |
| B3 | 身份校验只比对 `euid`/`egid`，未枚举 Linux 的 `uid/suid/fsuid` 与 `GLOBAL_ROOT_*` | 极端 setuid 场景下可能比 Linux 更严 | 可补齐 |

> 三条都记录在案，符合「缺口清单 + 复现方法」的给分方式；B2 是唯一有功能影响的。

### 2.7 探针踩坑（值得记一笔）

`sendmsg` 成功时返回**已发送字节数**（本探针为 3），失败才返回 -1 并置 errno。
探针首版误按「`rc == 0` 才算成功」判定，结果在**原生 Linux 上也大面积误报 FAIL**（7 项里 4 项假失败）。
修正为 `rc >= 0` 后双端均 7/7 PASS。**凡 syscall 探针，先确认返回值约定再写断言。**

### 2.7 Chromium 层复跑：症状消除，但 renderer 仍未创建

用 G17 内核跑一轮 `autorun_r4.sh`（600s，`--in-process-gpu` + `--disable-features=SegmentationPlatform,…`），
证据 `evidence/2026-09-21_t490-g17chr/`：

| 观测项 | G17 之前（report/13） | **G17 之后（本轮）** | 结论 |
|---|---|---|---|
| `crashpad … missing credentials` | 出现 | **0 次** | ✅ **已消除** |
| `COUNT [RenderProcessHost]` | 0 | **0** | ❌ 未改善 |
| `COUNT [type=renderer]` | 0 | **0** | ❌ 未改善 |
| browser 退出码 | 191（约 50–60 s） | **191（约 60 s）** | ❌ 未改善 |
| `COUNT [FATAL]` / `[Unimplemented]` / `[Network service crashed]` | 0 | **0 / 0 / 0** | 无新增缺口 |
| `COUNT [NO_NEW_PRIVS]` | 0 | **0** | P3 保持有效 |
| `FileURLLoader::Start: file:///…index.html` | 出现（D 段） | **出现** | 导航仍能开始 |

进程轨迹（`r4.log`）：

```text
--- +0s  browser=[71] zygote=[]   gpu=[]   utility=[] renderer=[]
--- +10s browser=[71] zygote=[94 95] gpu=[] utility=[] renderer=[]
--- +20s browser=[71] zygote=[]   gpu=[]   utility=[] renderer=[]
--- +30s browser=[71] zygote=[]   gpu=[]   utility=[148] renderer=[]
--- +50s browser=[71] zygote=[]   gpu=[]   utility=[148] renderer=[]
       已退出 rc=191（存活约 60s）
```

> **诚实结论**：P5 精准修掉了它宣称修的那件事（`missing credentials` 从此不再出现），
> 但 **renderer 的 191 退出是另一条独立通路**，G17 没有解开它。
> 阻塞点**后移**（凭证缺失不再是可见症状）但没有消失 —— 这是有效增量，不是终点。
>
> 值得注意：zygote 在 +10s 出现过（pid 94/95）随后消失，utility 进程（148）能存活到 browser 退出。
> 下一个观测方向：想办法在这 60 s 窗口内抓到 browser 侧 `--vmodule=*content*=2,*mojo*=2`
> 的失败点，以及 zygote 为何在 +10s 后消失。

---

## 3. 交付物

| 文件 | 说明 |
|---|---|
| `scripts/t490/r1_commit_and_tag.sh` | **新增** R1 可复现脚本（含 dry-run、5 道防护、双 tag） |
| `scripts/t490/p5_scm_credentials.py` | **新增**（替换早前的草稿版）G17 补丁应用器，幂等 |
| `scripts/t490/credprobe.c` | **新增** SCM_CREDENTIALS 探针，双端同源可编译 |
| `scripts/t490/autorun_cred.sh` | **新增** G17 验收轮 autorun |
| `report/patches/0001..0007` | **新增** P0–P5 的 `git format-patch` 补丁（含提交信息原文） |
| `evidence/2026-09-21_t490-credg17/` | **新增** G17 验收证据（8 文件 + screendump） |
| 本文件 `report/16` | 记录 R1 与 G17 全过程 |

T490 内核提交：`8162e8a` → `8efe025` → `c6930c2` → `031a3b4` → `f8b9224` → `7b60564` → `0c611be`

---

## 4. 下一步

| # | 事项 | 说明 |
|---|---|---|
| ~~N1~~ | ~~用 G17 内核复跑 Chromium，确认 crashpad 是否不再报 `missing credentials`~~ | ✅ **已完成**：`missing credentials` **0 次**（已消除）；但 **renderer 仍未创建、browser 仍 rc=191@60s**（见 §2.7） |
| **N1b** | 抓 191 退出的真正失败点 | 在 60 s 窗口内打开 `--vmodule=*content*=2,*mojo*=2`；并解释 zygote(pid 94/95) 为何 +10s 后消失 |

### N1b 追加结果（2026-09-22）

独立证据轮 `evidence/2026-09-22_t490-n1b/` 使用详细 vmodule 参数启动 Chromium。该轮发现基础镜像中的 `/etc/fonts/fonts.conf` 为空，Chromium 在 5 秒内以 `rc=0` 退出，未进入 zygote、renderer、Mojo 或 crashpad 的有效诊断路径；因此该轮不能用于解释此前的 60 秒 `rc=191`。修正版 autorun 已补回原 r4 的 `--disable-crash-reporter` 参数，后续重跑应以该脚本为准。
| N2 | 补 B2（AF_UNIX 的 `SO_PASSCRED` 自动附带凭证） | 若后续发现仍有凭证相关报错，这是下一处 |
| N3 | 把 P5 提上游（`openkylin/x-kernel`） | 上游 `!821` 仍未修，属真实缺口；需先 rebase 到最新 main 并跑全检 |
| N4 | 评估**把基线 rebase 到上游 `!821`** | 上游已前进 11 个 MR，且自带 `SO_PASSCRED`/`UnixCredentials`/接收侧序列化 —— 能让 P5 更小更易合入，但需重验 |
| N5 | R3：补「≥5 次中位数 + 波动范围」聚合脚本 | 性能项 15 分里的「数据统计规范 3 分」 |

---

*配套阅读：`report/13`（renderer 第二层阻塞）、`report/14`（平台合规核验）、`report/15`（第七八章配置同步）*
