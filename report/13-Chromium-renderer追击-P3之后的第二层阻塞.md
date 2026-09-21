# Chromium renderer 追击：P3 之后的下一层阻塞（r2 / r3 / r4 实测）

> 编制：小格 · 2026-09-21 · 平台 T490 原生 Ubuntu 26.04 · QEMU 10.2.1 · **纯 TCG**
> 上游：`https://gitee.com/openkylin/x-kernel.git`
> 前序：`report/11-P2补丁-…md`、**`report/12-P3补丁-prctl的no_new_privs与Chromium子进程全灭.md`**
> 证据：`evidence/2026-09-21_t490-{r2,r3,r4}/`

---

## 1. 一句话结论

`report/12` 修好了"**所有子进程在 exec 之前就被 abort**"（P3）。本轮把下一个阻塞**向前推进了一层**，
并证明它是**性质不同的第二次死亡**：

| # | 结论 | 证据 |
|---|---|---|
| 1 | 子进程**现在能 exec 了**（P3 的真实验收） | C 段 GPU 子进程跑到了 Wayland/VAAPI 初始化，打出自己的日志行（pid 290/311） |
| 2 | 但标准多进程下 **GPU 子进程在自己的 main() 里以 191 静默退出** → 3 次后 `FATAL: GPU process isn't usable. Goodbye.` → 浏览器 rc=191 | `GPU process exited unexpectedly: exit_code=48896`，且 **48896 = 191 << 8**（Chromium 打的是原始 wait status） |
| 3 | 用 `--in-process-gpu` + `--disable-features=SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions` 之后，**导航第一次真的开始** | `VERBOSE1:content/browser/loader/file_url_loader_factory.cc:474] FileURLLoader::Start: file:///usr/share/html-test/index.html`（nnp 轮从未出现） |
| 4 | 但浏览器随后在 ~60 s 时**同样以 191 退出** | D 段 `已退出 rc=191（存活约 60s）`，且 `FATAL=0 / prctl=0` |
| 5 | renderer 至今**一次都没被创建** | `RenderProcessHost` 计数恒 0；watcher 全程 `renderer:` 恒空 |
| 6 | 内核侧**无 panic / trap / OOM**；未实现 syscall 只有 `landlock_create_ruleset`（浏览器自己调的 2 次）；**GPU 子进程没有触发任何未实现 syscall** | console 全局统计 |

→ **P3 的功劳是把"子进程全灭"变成"子进程能跑起来后再死"，这是两回事。**
   当前阻塞已从"fork/exec 之间"移到"**进程内部初始化 + 跨进程 IPC 建立**"。

---

## 2. r2 轮：否掉"被网络拖死"这个假设

`report/12` §6 曾提出假设：浏览器把 11 分钟全耗在注定失败的联网任务上（GCM / optimization-guide），
导航因此还没启动。r2 轮直接检验它：

| 段 | 配置 | 结果 |
|---|---|---|
| **A** | 多进程 + `--host-resolver-rules="MAP * ~NOTFOUND"`（让那些请求瞬间失败）+ `--disable-extensions` 等，240 s | 浏览器存活 240 s；`crash=0 / NO_NEW_PRIVS=0 / FATAL=0`（P3 稳定）<br>**但 `renderer` 与 `RenderProcessHost` 计数仍为 0**；A 段 260 行日志中 `DidStartNavigation`/`NavigationRequest`/`OpenURL`/`TabStrip`/`LoadURL` 全部 0 命中<br>末行 `Handling shutdown for signal 15.` = 被我 kill 的时刻 |
| **B** | `--single-process --no-zygote`，210 s | **仍 rc=191，存活仅 50 s**；同日志 `FATAL=0 / prctl=0 / NO_NEW_PRIVS=0` |

**结论：假设不成立**（至少不充分）。屏蔽网络并不能让 renderer 出现。

> ⚠️ **同时对 `report/12` 做过一处更正**：初稿把 `--single-process` 的 rc=191 归因于
> "子进程初始化跑在 browser 内撞上 P3 那条 prctl FATAL"。
> B 段实测显示补丁后**仍是 rc=191，但 prctl/FATAL 计数为 0** → 该归因**不成立**，已在 report/12 标注。

---

## 3. r3 轮：C / D 对照，拿到 48896 与"导航开始"

### 3.1 C 段：标准多进程（不带 `--in-process-gpu`）——**GPU 子进程的第二次死亡**

| 计数 | 值 |
|---|---|
| `GPU process isn'` | **1** |
| `FATAL` | **1** |
| `Network service crashed` | 1 |
| `NO_NEW_PRIVS` / `RenderProcessHost` / `renderer` | **0 / 0 / 0** |
| 存活 | rc=191，约 120 s |

日志原文（关键三连）：

```
[62:62:0921/090019.573882:ERROR:content/browser/gpu/gpu_process_host.cc:1005] GPU process exited unexpectedly: exit_code=48896
[62:62:0921/090019.574421:WARNING:content/browser/gpu/gpu_process_host.cc:1447] The GPU process has crashed 1 time(s)
…
[62:62:0921/090105.549737:WARNING:…] The GPU process has crashed 3 time(s)
[62:62:0921/090105.550373:FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:418] GPU process isn't usable. Goodbye.
```

**★ `48896 = 191 × 256`**，即该子进程的**原始 wait status 是 `0xBF00`**：
`WIFEXITED=true`、**退出码 = 191**。（Chromium 这里打的是未右移的 status，
用 shell 看就是 191 —— 这一点很容易被误读成一个"奇怪的错误码"。）

关键差别（相对 P3 之前）：
- P3 之前：GPU 子进程**死在 `execvp()` 之前**，浏览器连它的日志都收不到；
- P3 之后：GPU 子进程**跑到了自己的初始化里**（打出 `drm_render_node_path_finder`、
  `vaapi_wrapper`、`wayland_buffer_manager_gpu` 等行），**10–13 s 后才静默退出 191**，
  **且没有任何 ERROR/FATAL 行**。
- console 全局统计里，**GPU 子进程没有触发任何 unimplemented syscall**，
  内核也没有 panic/trap/OOM → **它的死是用户态内部的决定，不是内核把它打掉的**。

### 3.2 D 段：`--in-process-gpu` + `--disable-features=…` ——**导航第一次真的开始**

| 计数 | 值 |
|---|---|
| `GPU process isn'` / `FATAL` | **0 / 0** |
| `RenderProcessHost` / `renderer` | **0 / 0** |
| 存活 | rc=191，约 **60 s** |

日志里出现了 nnp / r2 两轮**从未出现过**的一行：

```
[374:441:0921/090321.037182:VERBOSE1:content/browser/loader/file_url_loader_factory.cc:474]
    FileURLLoader::Start: file:///usr/share/html-test/index.html
```

紧跟其后：

```
[374:443:…ERROR:dbus/bus.cc:405] Failed to connect to the bus: …
[0921/090321.893446:ERROR:third_party/crashpad/crashpad/util/linux/socket.cc:177] missing credentials
[374:441:…VERBOSE1:components/signin/public/webdata/token_service_table.cc:259] Loaded tokens: result = 3
   ← 日志到此为止，进程随即以 191 退出
```

→ 结论两条：
1. **`--disable-features=SegmentationPlatform,OptimizationGuideModelDownloading,
   OptimizationHints,WebAppProvider,InterestFeedContentSuggestions` 确实把启动从"永不完成"
   变成"60 s 内走到导航"** —— 启动期特性确实在拖时间；
2. 但**导航一启动，浏览器就死**（191），renderer 仍然没被创建。

### 3.3 关于 191 的诚实标注

191 出现在**三个互不相同的位置**：标准多进程的 GPU 子进程、`--single-process` 的浏览器、
以及"导航刚开始"时的浏览器。它们的共同点只有一条：
**都正处在"建立/使用跨进程 IPC 通道"的路径上**。

但**本轮没有拿到 191 的出处**（上游源码里对应的 `_exit(191)`/`TerminateProcess(191)` 调用点未定位）。
按本项目纪律：**不做过早归因**，只登记现象 + 线索。已确认的相邻线索是
`crashpad/util/linux/socket.cc:177 missing credentials` → 指向 **`SO_PEERCRED`**
（取对端进程凭据）不可用 —— 已交给 `compatprobe`（§4）逐项体检。

---

## 4. r4 轮：兼容性体检（`scripts/t490/compatprobe.c`）

思路：不再从 Chromium 日志反推，而是**把 Chromium / Mojo / crashpad 强依赖、但 x-kernel
未必实现**的接口逐项打 errno，用证据登记缺口。

体检项：

| 组 | 项 |
|---|---|
| unix socket | `socketpair(STREAM / SEQPACKET / DGRAM / STREAM\|CLOEXEC\|NONBLOCK)`、`getsockopt(SO_PEERCRED)`、`getsockopt(SO_SNDBUF)`、`sendmsg(MSG_NOSIGNAL)`、`recv` |
| 共享内存 | `memfd_create` + `ftruncate`、`shm_open` + `ftruncate` + `mmap(MAP_SHARED)`、`/dev/shm` 可写性 |
| 事件/定时器 | `eventfd` 写读、`timerfd_create(CLOCK_MONOTONIC)`、`epoll_create1` + `epoll_ctl` + **`epoll_wait` 真等一次**、`signalfd` |
| 杂项 | `getrandom`、`madvise(MADV_DONTNEED)`、`prctl(PR_SET_PDEATHSIG)`、fork 后 fd 继承可用性 |

> 结果见 §4.1（本轮运行后回填）。

### 4.1 结果（跨 r4 / r5 / r7 三轮，最终口径）

> ⚠️ **本节经过三轮迭代才得到正确口径**，过程本身值得记录：
>
> | 轮次 | 探针问题 | 后果 |
> |---|---|---|
> | r4 | `madvise(栈缓冲, 16, …)` —— **地址非页对齐**，Linux 同样返回 EINVAL | 把 **G14 误报**为"madvise EINVAL"，实际是我的探针 bug |
> | r5 | 修正为页对齐 + 打出「打洞区间」用例，但 autorun 用 `probe \| tee` → **stdio 全缓冲**，进程结束时后半段输出整体丢失 | 只拿到前半段；且 `sendmsg` 失败后紧跟**阻塞 `recvmsg`** → 永久阻塞被误读为"内核卡住" |
> | r6 | 探针加 `setvbuf(_IONBF)`，autorun 改为落文件再显示 | 输出不再丢，但 `compatprobe` 仍因阻塞 `recvmsg` **HUNG 45 s** |
> | **r7** | 新增 **`hangprobe.c`**：每步前后 `write(2)` 直写 `dev/console`（不经 tee、不受重定向影响）+ `alarm(25)` 看门狗 | **一步不丢**，且 `ALARM_FIRED` 出现，直接证伪"内核卡死" |

**r4（首次）的原始输出**（保留以便对照，其中两条 FAIL 是探针自身缺陷）：

```
[CP] getrandom(16)                           rc=16   errno=0    PASS
[CP] madvise(MADV_DONTNEED)                  rc=-1   errno=22   FAIL   ← 探针 bug：地址未页对齐
[CP] prctl(PR_SET_PDEATHSIG,SIGKILL)         rc=-1   errno=22   FAIL   ← 真实缺口（G16）
[CP] child writes to inherited pipe fd       rc=0    errno=0    PASS
[CPSUM] pass=18 fail=2
[RESULT] HAD_FAILURE
```

```
[CP] socketpair(AF_UNIX,STREAM)              rc=0    errno=0    PASS
[CP] getsockopt(SO_PEERCRED)                 rc=0 len=12 pid=21 uid=0 gid=0
[CP]   -> peer pid matches                   rc=21   errno=0    PASS   ← 凭据是对的
[CP] getsockopt(SO_SNDBUF)                   rc=0 sbuf=65536      PASS
[CP] sendmsg(MSG_NOSIGNAL) on unix           rc=1    errno=0    PASS
[CP] recv() after MSG_NOSIGNAL send          rc=1    errno=0    PASS
[CP] socketpair(AF_UNIX,SEQPACKET)           rc=0    errno=0    PASS
[CP] socketpair(AF_UNIX,DGRAM)               rc=0    errno=0    PASS
[CP] socketpair(STREAM|CLOEXEC|NB)           rc=0    errno=0    PASS
[CP] memfd_create + ftruncate                rc=0    errno=0    PASS
[CP] shm_open + ftruncate + mmap(MAP_SHARED) rc=0    errno=0    PASS   ← 共享内存可用
[CP] open(/dev/shm/.xk6probe)                rc=3    errno=0    PASS
[CP] eventfd write+read                      rc=8    errno=0    PASS
[CP] timerfd_create(CLOCK_MONOTONIC)         rc=3    errno=0    PASS
[CP] epoll_ctl(ADD, pipe read end)           rc=0    errno=0    PASS
[CP] epoll_wait sees readable pipe           rc=1    errno=0    PASS
[CP] signalfd(SIGCHLD)                       rc=3    errno=0    PASS
[CP] getrandom(16)                           rc=16   errno=0    PASS
```

### 4.1.1 最终口径：tag `r7` 的 `hangprobe`（一步不丢，含负对照）

```
[HP] MARK 1a mmap(3 pages)
[HP] mmap(3p)                                   rc=0    errno=0
[HP] MARK 1b munmap(middle page)
[HP] munmap(middle page)                        rc=0    errno=0
[HP] MARK 2a ABOUT TO munmap(a, 3*P)  <-- 区间中间有洞
[HP] munmap(range with hole)                    rc=0    errno=0      ← 不卡、不报错 ✓
[HP] madvise(aligned,DONTNEED)                  rc=0    errno=0      ← 正常
[HP] madvise(misaligned)                        rc=-1   errno=22     ← 负对照，与 Linux 一致 ✓
[HP] madvise(HOLE)                              rc=-1   errno=12     ← ★ ENOMEM，Linux 返回 0
[HP] madvise(MADV_NORMAL)                       rc=-1   errno=22     ← ★ Linux 返回 0
[HP] madvise(MADV_WILLNEED)                     rc=-1   errno=22     ← ★ Linux 返回 0
[HP] madvise(MADV_FREE)                         rc=-1   errno=22     ← ★ Linux 返回 0
[HP] sendmsg(SEQPACKET+SCM_CREDENTIALS)         rc=-1   errno=22     ← ★ Linux 返回 1
[HP] ALARM_FIRED（信号可送达，说明未完全失联）      ← 25s 看门狗证明：**不是内核卡死**
[HP]   NO SCM_CREDENTIALS (rc=-1 controllen=0)
[HP] prctl(PR_SET_PDEATHSIG)                    rc=-1   errno=22     ← ★ Linux 返回 0
[HP] MARK Z ALL_STEPS_REACHED
[HP] ================ end ================
```

（`hangprobe` 结果 = 0，等待 24 s；`compatprobe` 在同轮被判定 **HUNG 45 s → kill -9**，
原因就是它 `sendmsg` 失败后紧跟**阻塞 `recvmsg`** —— 探针缺陷，不是内核问题。）

### 4.1.2 缺口清单（4 项，全部有 errno 级证据）

| # | 调用 | x-kernel | Linux | 证据 | 严重度判断 |
|---|---|---|---|---|---|
| **G14** | `madvise(MADV_DONTNEED)` 跨**未映射空洞**的区间 | **ENOMEM(12)** | **0** | `[HP] madvise(HOLE) errno=12`；源码 `aspace.rs::madvise_dontneed` 用 `covering_vmas_in_range()` **要求 VMA 连续覆盖** | 分配器/运行时常见的"区间内含空洞"调用会失败；**已修（P4）** |
| **G15** | `madvise(MADV_NORMAL / WILLNEED / FREE)` | **EINVAL(22)** | **0** | `[HP]` 三行 errno=22；源码 `mmap.rs::dontneed_from_raw` 的白名单**只有 MADV_DONTNEED** | 只有 DONTNEED 有实际动作，其余按 Linux 属"可忽略提示"；**已修（P4）** |
| **G16** | `prctl(PR_SET_PDEATHSIG, sig)` | **EINVAL(22)** | **0** | 探针 FAIL + **内核串口同步打印 `sys_prctl: unsupported option 1`**（option 1 = PR_SET_PDEATHSIG） | `base/process/launch_posix.cc` 里紧邻 P3 那段的下一分支，失败即 `RAW_LOG(ERROR)` + **`_exit(127)`**；本轮日志尚未见触发，**故意不修**（见下） |
| **G17** | `sendmsg(SEQPACKET)` 携带 `SCM_CREDENTIALS` | **EINVAL(22)** | **0** | `[HP] sendmsg(SEQPACKET+SCM_CREDENTIALS) errno=22`；实测 `SO_PEERCRED` 正常，**所以 crashpad 那句 `missing credentials` 的根因是它** | crashpad `UnixCredentialSocket` 靠 `SCM_CREDENTIALS` 认客户端；**下一轮主攻** |

**关于 G16 为什么不修**：把 `PR_SET_PDEATHSIG` 改成"接受并返回 0"等于**说谎** ——
信号根本不会被投递。诚实的修法是记录 sig 并在父线程退出时投递；
那是**新功能**而不是 errno 修正，本轮不夹带（避免把"看起来绿了"当成"语义对了"）。

### 4.1.3 被**否掉**的假设（同样有价值）

| 假设 | 结论 | 证据 |
|---|---|---|
| crashpad 的 `missing credentials` 是 `SO_PEERCRED` 不可用 | ❌ **否掉** | `getsockopt(SO_PEERCRED)` rc=0，`len=12`，`pid` 与 `getpid()` 一致，`uid/gid=0` 正确；真正缺的是 `SCM_CREDENTIALS`（G17） |
| GPU 子进程死于共享内存不可用 | ❌ 否掉 | `memfd_create`、`shm_open`+`ftruncate`+`mmap(MAP_SHARED)`、`/dev/shm` 全部 PASS |
| 死于 Mojo 需要的 socket 变体缺失 | ❌ 否掉 | `SEQPACKET` / `DGRAM` / `CLOEXEC\|NONBLOCK` / `sendmsg(MSG_NOSIGNAL)` / `SO_SNDBUF` 全 PASS |
| 死于事件循环原语缺失 | ❌ 否掉 | `eventfd` 写读、`timerfd`、`epoll_ctl` + **`epoll_wait` 真等一次**、`signalfd` 全 PASS |
| 死于 fd 跨 fork 不可用 | ❌ 否掉 | `child writes to inherited pipe fd` PASS |
| **`munmap` 跨"带洞区间"会卡死/报错**（r5/r6 疑似） | ❌ **否掉** | `[HP] munmap(range with hole) rc=0`；而 r5/r6 的"卡住"实为**探针里 `sendmsg` 失败后接了一个阻塞 `recvmsg`** |


一个漂亮的**交叉确认**：探针打 `prctl(PR_SET_PDEATHSIG)` 的同时，**内核串口**同步打印了

```
ksyscall::task::ctl:213] sys_prctl: unsupported option 1
```

`option 1` 正是 `PR_SET_PDEATHSIG(1)` —— 与源码一致：它不在 `sys_prctl` 的匹配表里，
落到 `_ => { warn!(...); Err(KInvalidInput) }`。

#### 4.1.4 关于 `SCM_CREDENTIALS` 的线索修正

crashpad 那句 `socket.cc:177 missing credentials` 来自它的 `UnixCredentialSocket`，
它**等的不是 `SO_PEERCRED` 而是 `SCM_CREDENTIALS` 控制消息**
（`UnixCredentialSocket` 用 `SOCK_SEQPACKET` socketpair，并在 `sendmsg` 里显式附带凭据）。
实测结论：

- `getsockopt(SO_PEERCRED)` **完全正常**（`uid/gid/pid` 都对）→ 先用它当假设的方向是错的；
- 真正失败的是 **`sendmsg` 携带 `SCM_CREDENTIALS` → EINVAL(22)**（G17）。

### 4.2 P4 补丁：madvise 的 advice 白名单 + 容忍未映射空洞

| 项 | 内容 |
|---|---|
| 应用器 | `scripts/t490/p4_madvise.py`（精确匹配 / 幂等 / 不盲改，4 处改动） |
| 落点 1 | `posix/mm/src/mmap.rs::MadviseRequest::dontneed_from_raw()`：advice 白名单由"只有 `MADV_DONTNEED`"扩为 `MADV_NORMAL \| MADV_RANDOM \| MADV_SEQUENTIAL \| MADV_WILLNEED \| MADV_FREE`（返回 `Ok(None)` → `sys_madvise` 回 0），其余仍 `EINVAL` |
| 落点 2 | `mm/memspace/src/aspace.rs::madvise_dontneed()`：把 `covering_vmas_in_range(range)?`（**要求 VMA 连续覆盖，遇洞即 ENOMEM**）换成 `self.vmas.collect_overlapping(range)`（容忍空洞）；仍保留 `validate_region()` 的"页对齐 + 在地址空间内"校验，与 Linux 报错条件一致 |
| 落点 3/4 | 更新被语义变更影响的单测：`madvise_dontneed_requires_fully_mapped_range` → `madvise_dontneed_tolerates_unmapped_gaps`，断言改为"区间内的已映射页仍被丢弃" |
| **刻意不改** | `munmap` 跨洞（实测 rc=0，无缺口）；`prctl(PR_SET_PDEATHSIG)`（见 G16 的说明：改成返回 0 等于说谎，应作为新功能单独做） |
| 构建 | `make build` → **BUILD_EXIT=0** |
| 验证 | tag `p4` 轮（探针 + 标准多进程 Chromium），结果见 §4.2.1 |

> 注意：`posix/mm/src/lib.rs` 的既有单测 `madvise_request_rejects_unsupported_advice` 用的是
> advice=`999`，不在新白名单里，因此**不需要改**（补丁刻意保留了"未知 advice → EINVAL"）。

#### 4.2.1 验证结果（tag `p4`）

**① 探针侧：4 项全部转正，负对照未被放水**

| 项 | 补丁前（r7） | 补丁后（p4） |
|---|---|---|
| `madvise(HOLE in middle)` | rc=-1 errno=**12** (ENOMEM) | **rc=0 errno=0** ✓ |
| `madvise(MADV_NORMAL)` | rc=-1 errno=**22** | **rc=0 errno=0** ✓ |
| `madvise(MADV_WILLNEED)` | rc=-1 errno=**22** | **rc=0 errno=0** ✓ |
| `madvise(MADV_FREE)` | rc=-1 errno=**22** | **rc=0 errno=0** ✓ |
| `madvise(aligned, DONTNEED)`（回归） | rc=0 | **rc=0** ✓ |
| `madvise(misaligned)`（**负对照**） | rc=-1 errno=22 | **rc=-1 errno=22** ✓ 未放水 |
| `munmap(range with hole)`（回归） | rc=0 | **rc=0** ✓ |
| `hangprobe` 整体 | `ALL_STEPS_REACHED` | **`ALL_STEPS_REACHED`** |

```
[HP] madvise(HOLE)                              rc=0    errno=0
[HP] madvise(MADV_NORMAL)                       rc=0    errno=0
[HP] madvise(MADV_WILLNEED)                     rc=0    errno=0
[HP] madvise(MADV_FREE)                         rc=0    errno=0
[HP] MARK Z ALL_STEPS_REACHED
[p4]   /hangprobe 结果=0（等待 24s）
[p4]   /nvprobe 结果=0（等待 1s）   ← P3 回归
[p4]   /p2probe 结果=0（等待 1s）   ← P2 回归
```

**② 行为侧：P4 并没有救活 GPU 子进程 —— 这是一条**否定结论**，必须写清**

标准多进程（不带 `--in-process-gpu`）跑 220 s：

```
[p4] browser pid=153
[p4] 已退出 rc=191（存活约 120s）
[p4]   COUNT [GPU process exited]   = 3
[p4]   COUNT [GPU process isn']     = 1
[p4]   COUNT [FATAL]                = 1
[p4]   COUNT [RenderProcessHost]    = 0
```

与 r3-C 段**完全一致**（同样 3 次 GPU 崩溃 → `FATAL: GPU process isn't usable` → 浏览器 191）。

→ **诚实的结论**：`madvise` 的 G14/G15 是**真实缺口**，且有 errno 级证据与探针级验证；
但它们 **不是** GPU 子进程静默 exit 191 的死因。
（纪律：**不许把"顺手修好的另一个 bug"当成"解决了目标问题"**。
这也说明"madvise 失败 → CHECK → 静默退出"那条**推演**不成立 —— 推演本身就是未被证实的假设。）

→ 至此，`GPU 子进程 exec 成功后 10–13 s 静默 exit 191` 仍是一个**未定位的独立阻塞**，
  下一步靠 §5 的第 2 条（提高 VLOG 级别 / 采样 `wchan`）继续定位。



### 4.3 r4 的 D 段复跑：确认"导航开始"可复现

| 观测 | 结果 |
|---|---|
| `FileURLLoader` 命中 | **1**（`FileURLLoader::Start: file:///usr/share/html-test/index.html`） |
| `missing credentials` 命中 | **1** |
| 浏览器存活 | 约 **50 s**（11:15:31 起，日志止于 11:16:21），随后消失 |
| watcher 全程（+0 → +210 s，每 30 s） | `browser=` **恒空**、`renderer=[]` **恒空** → 没有重启，也没有派生 renderer |
| `RenderProcessHost` / `type=renderer` / `renderer` / `FATAL` 计数 | **0 / 0 / 0 / 0** |

→ r3-D（60 s 死）与 r4-D（50 s 死）**形态一致**：**浏览器会走到"开始加载页面"这一步，然后死去**，
且**始终没有创建 renderer**。这让"导航开始 → 需要 renderer → 死"成为一个具体的、可复现的观察窗口。

### 4.4 由 r2/r3/r4 共同收敛出的阻塞图

```
P3 之前：  browser ──spawn──> child ──X(prctl FATAL, exec 之前)──>  子进程全灭
P3 之后：  browser ──spawn──> child ──exec OK──> 子进程内部初始化
                                        ├─ GPU 子进程：10~13 s 后静默 exit 191 → 3 次后 browser FATAL
                                        └─ renderer  ：从未被创建（RenderProcessHost 计数恒 0）
D 配置绕过 GPU 进程后：browser ──> 启动跑完 ──> FileURLLoader::Start ──X(exit 191, ~50-60 s)
```

**内核侧在整条链上唯一的"主动报错"只有两个 errno：`madvise(MADV_DONTNEED)` 与
`prctl(PR_SET_PDEATHSIG)` 的 EINVAL（G14/G15）** —— 这就是下一步的靶子。


---

## 5. 下一步（按优先级）

1. **G17 `SCM_CREDENTIALS`**（下一轮主攻）。理由：它是 crashpad "missing credentials" 的**已证实**根因，
   且已排除 `SO_PEERCRED`；crashpad 是 Chromium 每个进程都会启的组件。
   落点预计在 `net/knet/src/unix/`（`sendmsg` 的 cmsg 处理）——注意：dgram 路径已支持 ancillary，
   但 `sendmsg` 携带 `SCM_CREDENTIALS` 在 **SEQPACKET** 上返回 EINVAL，需要先定位是哪一层拒绝。
2. **查清"191"的出处**：`--vmodule=*content*=2,*mojo*=2`（或 `--v=2`）短跑 90 s；
   也可加一个周期性采样 `/proc/<pid>/task/*/wchan` + `/proc/<pid>/status` 的宿主侧探针
   （x-kernel **无 ptrace**，`strace` 不可用）。
3. **复查 P4 是否影响 GPU 子进程之死**：见 §4.2.1 —— 若 std 多进程下 GPU 仍静默 191，
   则 G14/G15 虽是真缺口但不是它的死因，**不许把它当成功**。
4. **补齐 `compatprobe` 的 `SO_PASSCRED` 用例**（自动附加凭据的路径，与显式 cmsg 不同）。
5. **固化 D 段配置**进 `autorun`：`--disable-features=SegmentationPlatform,
   OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,
   InterestFeedContentSuggestions` 能把"永不完成启动"变成"50 s 内走到导航"，
   对**浏览器 UI 稳定渲染**这一档证据（现有 `shot-06`）是有价值的工程兜底。

---

## 6. 复现

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/xk6

# r2：否掉网络假设 + single-process 对照
BASE_IMG=$HOME/x-kernel/images/pkg-installed.img PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh r2 760 60 autorun_r2.sh nvprobe.c

# r3：C（标准多进程）/ D（in-process-gpu + disable-features）对照
… bash ~/xk6/scripts/t490/t490_round.sh r3 780 60 autorun_r3.sh nvprobe.c

# r4：兼容性体检 + D 段复跑
… bash ~/xk6/scripts/t490/t490_round.sh r4 420 20 autorun_r4.sh compatprobe.c nvprobe.c

# 每轮结束后回收 guest 完整日志（console 只有 tail 窗口）
bash ~/xk6/scripts/t490/pull_guest_logs.sh <tag> [/root/r3-C.log /root/r3-D.log …]
```

---

## 7. 本轮新增的方法教训

1. **`exit_code=48896` 要 `/256` 才是 shell 看到的 191**（Chromium 打原始 wait status）。
   看到怪异的大数字先做这一步换算，否则会把它当成"另一个未知错误"。
2. **"子进程能 exec" 与 "子进程能活" 是两个独立命题**：P3 解决前者，r3 证明后者是新的、
   性质不同的阻塞。汇报时必须分开说，否则会把功劳和问题混在一起。
3. **假设要写进报告并显式检验**：`report/12` §6 的"网络拖死"假设被 r2 直接否掉，
   已在 report/12 就地标注更正 —— 不留"看起来像结论的猜测"。
4. **`--disable-features` 是排查启动期卡顿的有效杠杆**：它把"永不导航"变成"60 s 内导航"，
   是一个能区分"启动慢"与"功能缺"的廉价手段。
5. **交付物与实验可以并行**：本轮先启动 r4 会话（后台），期间完成 `report/12` 的更正与
   `report/13` 的撰写，不空等。
