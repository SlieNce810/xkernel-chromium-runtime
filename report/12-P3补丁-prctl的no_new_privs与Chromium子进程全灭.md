# P3 补丁：`prctl(PR_SET_NO_NEW_PRIVS)` 返回 ENOSYS，导致 Chromium 所有子进程在 `execve` 之前被 FATAL

> 编制：小格（赛题六 · 兼容性缺口与补丁）· 2026-09-21
> 上游：`https://gitee.com/openkylin/x-kernel.git` · 平台：T490 原生 Ubuntu 26.04 · QEMU 10.2.1 · **纯 TCG**
> 前序：`report/09-兼容性缺口G4-unix-stream-SCM_RIGHTS.md`（P1）、`report/11-P2补丁-sched的tid解析与netlink多播组.md`（P2）
> 证据：`evidence/2026-09-21_t490-nnp/`（含 guest 内完整 `chromium.log` 336 行与 4 张场转截图）

---

## 1. 一句话结论

Chromium 在 **`fork()` 之后、`execvp()` 之前**调用 `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`，
并且**只容忍 `EINVAL` 与 `EPERM`**；而 x-kernel 对该 option **无条件返回 `ENOSYS(38)`**
→ 命中 `RAW_LOG(FATAL)` → **每一个子进程都在 exec 之前被 abort**。

补齐这一处语义（**改 1 个文件、+20 行**）后：

| 指标 | 补丁前 | 补丁后 |
|---|---|---|
| `Network service crashed or was terminated` | 每 ~4–5 s 一次（P2 轮 120 行窗口内 30 次） | **完整 336 行 / 11 分钟内 0 次** |
| 无前缀的 `prctl(PR_SET_NO_NEW_PRIVS) failed` | 与崩溃 1:1 出现 | **0 次**（整类消失） |
| `zygote` / `utility(network service)` / `crashpad` | 起来即死，从不常驻 | **稳定常驻**（`ZygoteMain: initializing 0 fork delegates`） |
| 浏览器存活 | 需 `--in-process-gpu` 才勉强活，子进程仍全灭 | **连续 >700 s，无 FATAL/Aborted** |
| 屏幕画面 | 纯黑窗 | **Chromium UI 完整渲染**（标签栏 + 地址栏 + 菜单，见 §5.4） |

仍未解决的问题只剩下一个：**renderer 始终未出现**（浏览器连"尝试派生"都没有），详见 §6。

---

## 2. 现象（补丁前）

`/root/chromium.log` 里每 ~4–5 s 循环：

```
[179:179:…:ERROR:content/browser/network_service_instance_impl.cc:722] Network service crashed or was terminated, restarting service.
prctl(PR_SET_NO_NEW_PRIVS) failed
```

注意第二行**没有** `[pid:tid:时间:级别:文件:行]` 前缀 —— 这不是格式问题，
而是它是**子进程在 Chromium 的前缀日志机制之外直接写进共享 stderr** 的（§3.1）。
另外：
- `renderer` 恒为空；`chromium.log` 里**只有 browser 自己的 PID**（子进程零输出）
- `--single-process --no-zygote` → **rc=191**（旧结论："不是退路"）
- 无 panic / trap / OOM；未实现 syscall 只剩 `landlock_create_ruleset`
- `childprobe` 的 C1–C5（`/proc/self/exe`、`fork`、`fork+execve`、`/bin/busybox`）**全部 PASS**
  → 已排除"子进程启动通路本身有问题"

**这四件事彼此矛盾**：既然 fork/execve 都正常，为什么子进程连一行日志都来不及打？P3 给出了统一解释。

---

## 3. 根因链（三段，全部有源码级出处）

### 3.1 Chromium 侧：这条 `prctl` 在 fork 与 exec **之间**

`base/process/launch_posix.cc` → `LaunchProcess()` 的子进程分支
（位于 `CloseSuperfluousFds()` 之后、`chdir()` / `execvp()` 之前），逐字：

```cpp
#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_AIX)
#ifndef PR_SET_NO_NEW_PRIVS
#define PR_SET_NO_NEW_PRIVS 38
#endif
    if (!options.allow_new_privs) {
      if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
        // EINVAL means PR_SET_NO_NEW_PRIVS is unsupported (kernel < 3.5)
        // EPERM indicates a problem with the environment out of our
        // control (e.g. a system-imposed seccomp bpf sandbox)
        if (errno != EINVAL && errno != EPERM) {
          RAW_LOG(FATAL, "prctl(PR_SET_NO_NEW_PRIVS) failed");
        }
      }
    }
    if (options.kill_on_parent_death) { … }
#endif
    …
    execvp(executable_path, argv_cstr.data());
```

三点关键：
1. 它在 **exec 之前**，所以子进程死时目标可执行文件**还没被加载** → "子进程零输出"就说得通了；
2. 它是 `RAW_LOG`（原始 stderr 写），**不带 `[pid:tid:…]` 前缀** → "那行日志没有前缀"说得通了；
3. 对比紧随其后的 `PR_SET_PDEATHSIG` 分支：那个失败只 `RAW_LOG(ERROR)` + `_exit(127)`,
   而这个是 **`RAW_LOG(FATAL)`**，直接崩溃。
   > 另注：x-kernel 的 `PR_SET_PDEATHSIG` 也不在分发表里（落到 `_ =>` 返回 `EINVAL`），
   > 但 `kill_on_parent_death` 这一路目前未被触发，暂不影响；已登记为待观察项。

### 3.2 errno 语义错配就是崩溃

| errno | 数值 | Chromium 行为 |
|---|---|---|
| `EINVAL` | 22 | **容忍** —— 视为"内核 < 3.5 不支持" |
| `EPERM` | 1 | **容忍** —— 视为"环境自身限制" |
| **`ENOSYS`** | **38** | **不在容忍集 → `RAW_LOG(FATAL)` → 子进程 abort** |

这正是本赛题中最典型的"**行为缺陷**"形态：功能都在，**只是一个 errno 用错了**。

### 3.3 x-kernel 侧（补丁前的源码）

`core/ksyscall/src/task/ctl.rs`：

```rust
PR_SET_NO_NEW_PRIVS => {
    if arg2 != 1 || arg3 != 0 || arg4 != 0 || arg5 != 0 {
        return Err(KError::InvalidInput);
    }
    return Err(KError::from(LinuxError::ENOSYS));      // ← 无条件 ENOSYS
}
```

这一臂甚至**先按 Linux 语义校验了参数**，然后再返回 ENOSYS —— 说明它不是"没实现"，
而是上游**有意识地拒绝**（单测名就是证据）：

```rust
#[def_test(user, serial)]
fn prctl_set_no_new_privs_requires_exec_enforcement() {
    assert_eq!(sys_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0),
               Err(KError::from(LinuxError::ENOSYS)));
}
```

上游的顾虑是正当的：`no_new_privs` 的语义是"execve 不会授予原本没有的权限"，
若内核不真的在 exec 路径上做这一步，它就是**在说谎**。
但结论下错了 —— 见 §4 的语义论证。

### 3.4 这条链一次解释掉全部四个"矛盾"事实

| 此前解释不通的现象 | P3 的解释 |
|---|---|
| 子进程**零输出**（日志里只有 browser 的 PID） | 死在 `execvp()` 之前，目标程序从未启动 |
| `prctl(PR_SET_NO_NEW_PRIVS) failed` **没有 `[pid:tid:…]` 前缀** | 子进程直接 `RAW_LOG` 到共享 stderr，不走 Chromium 日志前缀机制 |
| `childprobe`（`fork`/`execve`/`/proc/self/exe`）**全绿**却仍无 renderer | 探针没有调 `prctl(PR_SET_NO_NEW_PRIVS)`，因此正好**绕过了唯一坏掉的那一步** |
| `GPU process isn't usable. Goodbye.`（rc=191） | GPU 子进程同样是"起来即死"，只是它第一个被发现 |

> ⚠️ **已更正的一条**：本报告初稿把 `--single-process --no-zygote` 的 rc=191 也归因于
> "子进程初始化跑在 browser 内撞同一条 FATAL"。**r2 轮的实测推翻了它**：
> 补丁后 `--single-process` 仍然 **rc=191（存活 50 s）**，但同一份日志里
> `FATAL` / `prctl` / `NO_NEW_PRIVS` 计数**全为 0**。
> 即：该模式的失败另有原因，与 P3 无关。详见 `report/13-…-renderer追击.md`。

---

## 4. 修法

### 4.1 改动（`core/ksyscall/src/task/ctl.rs`，+20 行）

```rust
PR_SET_NO_NEW_PRIVS => {
    // Linux 3.5+: record the sticky "no privilege gain on execve" flag and
    // return 0. … Refusing with ENOSYS here is NOT compatible: user space is
    // entitled to probe with EINVAL/EPERM (see chromium
    // base/process/launch_posix.cc), and an unexpected errno turns a
    // best-effort hardening step into a fatal one — every Chromium child
    // aborts right after fork(), before execvp().
    if arg2 != 1 || arg3 != 0 || arg4 != 0 || arg5 != 0 {
        return Err(KError::InvalidInput);
    }
    kprocess::current_user_thread().set_no_new_privileges();
}
```

配套：模块级与测试模块的 `LinuxError` 导入清理；单测由"断言 ENOSYS"改为
"校验 EINVAL + latch 往返（set → 0、get → 1、再 set 仍 0/1）"。

### 4.2 为什么这是**真语义**而不是桩

1. x-kernel **没有** setuid / setgid / 文件能力所导致的特权提升路径
   （单一 root、无 SUID 处理），所以"execve 不会授予原本没有的权限"这句话
   **在这里天然成立** —— 记录该位并返回 0 是对真实行为的**如实描述**，不是谎言。
2. **状态字段和继承早就写好了**，只是没被这一臂用上：
   - `process/kprocess/src/thread/core.rs`：`no_new_privileges: AtomicBool`、
     `no_new_privileges()` / `set_no_new_privileges()`
   - `prepare_process_fork()`（fork）与 `prepare_thread_clone()`（clone）
     **都已**把 `self.no_new_privileges()` 传给子线程
   → 也就是说 fork/clone 继承语义**本来是对的**，只有 `PR_SET_NO_NEW_PRIVS` 这一臂没接上。
3. 返回 0 与 Linux 3.5+ 一致；`PR_GET_NO_NEW_PRIVS` 本来就是读这个位，
   补丁后 SET/GET 终于形成闭环。

> 备选方案（**未采用，但值得记录**）：只把返回值从 `ENOSYS` 改成 `EINVAL` 也能让
> Chromium 容忍并继续 exec（因为它在容忍集里）。但那等于"**骗过调用方**"——
> 让用户态以为内核不支持，而其实内核可以支持。本次选择给真语义。

### 4.3 应用器

`scripts/t490/p3_prctl_nonewprivs.py` —— 精确匹配 / 幂等 / 不盲改
（要求每个 old 串**恰好出现一次**，否则拒绝执行）。本轮输出：

```
[ok] core/ksyscall/src/task/ctl.rs: 行数变化 +20
     - PR_SET_NO_NEW_PRIVS 实现
     - 模块级导入去掉 LinuxError
     - 测试模块导入去掉 LinuxError
     - 单测改为 latch 往返
```

构建：`make build` → **BUILD_EXIT=0**（`Built …/kplat-aarch64/release`，产物 `xkernel_aarch64-qemu.bin` 8 254 720 B）
改动量：**1 个文件 / +20 行**。

---

## 5. 验收

### 5.1 专用探针直接验证（`scripts/t490/nvprobe.c`）

不依赖 Chromium 日志推断，直接调 syscall / libc：

```
[NV] pid=39 tid=39
[NV] T0 PR_GET_NO_NEW_PRIVS (before) = 0 errno=0
[NV] T1 PR_SET_NO_NEW_PRIVS(1) -> rc=0 errno=0                 ← 补丁前：rc=-1 errno=38 (ENOSYS)
[NV] T1 set returns 0 (was ENOSYS=38)             PASS
[NV] T2 PR_GET_NO_NEW_PRIVS (after) = 1 errno=0                ← SET/GET 闭环
[NV] T2 get reads back 1                          PASS
[NV] T3 PR_SET_NO_NEW_PRIVS(0) -> rc=-1 errno=22               ← EINVAL(22) 校验保留
[NV] T3 arg2=0 rejected with EINVAL(22)           PASS
[NV] T4 fork child read  -> 1 (raw exit=0)                     ← fork 继承
[NV] T4 flag inherited across fork                PASS
[NV] T5 chromium-style child exit=0                            ← 逐字复刻 LaunchProcess 判据 + execve
[NV] T5 chromium-style child survives execve      PASS
[RESULT] ALL_PASS
```

**T5 是本补丁的核心探针**：它逐字复刻了 §3.1 那段代码的失败判据
（`if (prctl(...)) { if (errno != EINVAL && errno != EPERM) { 写 stderr; _exit(134); } }`），
后面接 `execl("/bin/sh", …)`。补丁前必然停在 `134`（abort 等价），现在 `exit=0`。

### 5.2 全局计数（**before/after**）

★ 方法纪律：**"某类日志是否消失"必须全局 `grep -c`，绝不能看 tail 窗口**（P2 轮曾因此误判）。

| 模式 | 补丁前（P2 轮） | 补丁后（本轮，完整 336 行 / 11 分钟） |
|---|---|---|
| `Network service crashed` | 每 ~4–5 s 一次（120 行窗口内 30 次） | **0** |
| `NO_NEW_PRIVS` / `prctl` | 与崩溃 1:1（同窗口 13 次） | **0** |
| `pthread_getschedparam failed` | 曾有（P2 已修） | **0**（P2 未回退） |
| `GPU process isn'` | 有（`GPU process isn't usable`） | **0** |
| `FATAL` / `Aborted` / `LaunchProcess` | — | **0 / 0 / 0** |
| `Failed to connect to Wayland` | 曾有 | **0** |

> 说明：P2 轮的完整 `chromium.log` 已随 `disk.img` 被覆盖（每轮换镜像），
> 故 before 侧采用 P2 轮 **console 中可见的那段日志窗口**的计数，并如实标注。
> after 侧是本轮从 guest 镜像里 `debugfs dump` 出来的**完整文件**。

### 5.3 进程格局（子进程首次常驻）

```
[nnp]     browser =[105 ]          ← 存活 200 s 采样窗口全程在
[nnp]     zygote  =[133 134]       ← 首次常驻（此前起来即死）
[nnp]     utility =[177]           ← network service，首次常驻
[nnp]     gpu     =[]              ← 因 --in-process-gpu 而并入 browser，符合预期
[nnp]     renderer=[]              ← 仍未出现，见 §6
```

guest 内 `ps` 还能看到两个 `chrome_crashpad_handler`（PID 129 / 131）常驻 ——
说明 crashpad 这一路也活了。浏览器进程 **105 连续存活 >700 s**。

### 5.4 视觉证据（功能证据，`screendump` 出图）

`evidence/2026-09-21_t490-nnp/screenshots/shot-06-at0346s.png`（1280×800，均值亮度 215.35）：

- Weston 桌面 + 顶部面板时钟（`Mon Sep 21, 08:32 AM`）—— 合成器正常
- **Chromium 窗口 UI 完整渲染**：标签栏（含 `+` 新建标签）、地址栏
  `File /usr/share/html-test/index.html`、前进/后退/刷新按钮、书签星标、头像、右上角菜单
- **此前同一位置是纯黑窗**（`report/10` 记录的形态）

→ 浏览器 UI（chrome 层）的 Skia 合成链路已经打通。
→ 但**内容区仍为空白、标签标题仍为 "Untitled"**（该测试页有
`<title>x-kernel Chromium 渲染自检页</title>` 与红色 banner `#c8102e`），
说明 **renderer 未加载文档**。

### 5.5 回归（前序补丁未被破坏）

| 探针 | 结果 |
|---|---|
| `/p2probe`（P2-a sched tid / P2-b netlink groups） | `[RESULT] ALL_PASS` |
| `/childprobe`（C1 readlink `/proc/self/exe`、C2 fork、C3 fork+execve、C4/C5 execve） | `[RESULT] ALL_PASS` |
| `/evprobe`（输入设备） | `event0 = "QEMU Virtio Keyboard"`，仍只有 1 个 evdev 节点（G6 未变） |
| QEMU 命令行 | **无任何 `-accel`** → 纯 TCG 自证通过 |

---

## 6. 仍未解决：renderer 从未被**尝试**创建

本轮 `chromium.log`（336 行）里对以下关键词的检索结果：

| 关键词 | 命中 |
|---|---|
| `RenderProcessHost` / `renderer` / `StartNavigation` / `NavigationRequest` / `CommitNavigation` | **0** |
| `zygote` / `Zygote` | 2（两条 `ZygoteMain: initializing 0 fork delegates`，仅启动日志） |
| watcher 全程 12 次采样（每 30 s，08:31→08:38） | `renderer:` **恒空**，`crash 计数: 0` |

即：**浏览器没有报错，也没有去派生 renderer，更没有导航**。
它把 11 分钟花在了 profile / 政策 / 扩展 / GCM / optimization-guide 这些启动期任务上，
日志里时间戳间隔常达 30–90 s（例如 `Delaying GCM registration of app: … for 215716 milliseconds`）。

当前最强假设（**已被后续实测推翻，见 §6.1**）：
启动期被"注定失败的联网任务"拖住，导航尚未启动
（guest 内 DNS 与 TCP 能通，但 TLS 握手 `net_error -101`、`TCP_KEEPIDLE` 返回
`ENOPROTOOPT(92)`，见 §7 缺口表），叠加 TCG 的极慢速。

### 6.1 后续实测：这个假设**被推翻**了（`autorun_r2.sh`，tag `r2`）

| 段 | 配置 | 结果 |
|---|---|---|
| **A** | 多进程 + `--host-resolver-rules="MAP * ~NOTFOUND"`（把注定失败的请求瞬间打死）+ `--disable-extensions` 等，240 s | browser 存活 240 s；`crash=0 / NO_NEW_PRIVS=0 / FATAL=0`（P3 稳定）<br>但 **`renderer` 与 `RenderProcessHost` 计数仍为 0**；A 段 260 行日志里 `DidStartNavigation`/`NavigationRequest`/`OpenURL`/`TabStrip`/`LoadURL` **全部 0 命中**<br>（末行为 `Handling shutdown for signal 15`，即被我 kill 的时刻） |
| **B** | `--single-process --no-zygote`（210 s） | **仍 rc=191，存活 50 s**；同日志 `FATAL=0 / prctl=0 / NO_NEW_PRIVS=0`<br>→ 该模式的失败**与 P3 无关**（见 §3.4 的更正） |

→ **"被网络拖住"不成立**（至少不充分）：屏蔽网络并不能让 renderer 出现。
→ 剩余阻塞位于 **"导航 / renderer 派生"这条路径本身**，需换探针方向。
   第三轮（`autorun_r3.sh`，tag `r3`）做 C/D 对照：
   **C = 去掉 `--in-process-gpu` 回到标准多进程**（补丁前这一档必 `GPU process isn't usable`，
   补丁后 GPU 子进程应能活 → 也许 `--in-process-gpu` 本身就是 renderer 路径的干扰项）；
   **D = 保留 `--in-process-gpu`**，只加 `--disable-features=SegmentationPlatform,
   OptimizationGuideModelDownloading,WebAppProvider,…` 砍启动期特性。


剩余非致命缺口（本轮日志实证）：

| 缺口 | 证据 | 影响 |
|---|---|---|
| `PR_SET_PDEATHSIG` 未实现（落 `_ =>` → `EINVAL`） | `ctl.rs` 分发表无该 option | 若 Chromium 启用 `kill_on_parent_death` 会 `_exit(127)` |
| `inotify_init()` → `ENOSYS(38)` | `file_path_watcher_inotify.cc:338` | 有 fallback，非致命（G12） |
| 无 DRM render node（`/dev/dri/renderD*`） | `drm_render_node_path_finder.cc:45 drmGetDevices2() has not found any devices` | VAAPI/硬件合成不可用；软件路径可绕 |
| `TCP_KEEPIDLE` → `ENOPROTOOPT(92)` | `tcp_socket_posix.cc:93` ×多 | 非致命 |
| 无 dbus | `Failed to connect to socket /run/dbus/system_bus_socket` | 非致命 |
| `landlock_create_ruleset` 未实现 | `dispatch:855 Unimplemented syscall` | 非致命（G13） |

---

## 7. 复现

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel

# ① 打补丁 + 构建
python3 ~/xk6/scripts/t490/p3_prctl_nonewprivs.py ~/x-kernel
make build                                    # 期望 BUILD_EXIT=0

# ② 验证（回归探针 + 本轮 autorun：weston + Chromium + 全局计数）
cd ~/xk6
BASE_IMG=$HOME/x-kernel/images/pkg-installed.img \
PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh nnp 700 60 autorun_nnp.sh \
       nvprobe.c p2probe.c childprobe.c evprobe.c

# ③ 停机后从镜像回收 guest 完整日志（console 只 echo 了 head/tail 各 60 行）
bash ~/xk6/scripts/t490/pull_guest_logs.sh nnp

# ④ 判定
D=~/xk6/evidence/$(date +%Y-%m-%d)_t490-nnp
tr -d '\r' < $D/console.log | grep -nE "^\[NV\]|^\[RESULT\]|COUNT \[|renderer|browser ="
grep -cE 'Network service crashed|NO_NEW_PRIVS' $D/guest/chromium.log   # 期望 0
```

---

## 8. 本轮新增的方法教训（都是踩过的）

1. **"某类日志是否消失"必须全局 `grep -c`**，不能看 tail 窗口 —— P2 轮因此误判过一次，
   本轮把这条写进了 autorun（`COUNT [...]` 段）。
2. **无前缀的 stderr 行是重要线索**：Chromium 的子进程日志经 browser 转发、带 `[pid:tid:…]`；
   一旦某行**没有**前缀，几乎可以断定它来自 fork/exec 之间的原始 stderr 写入 ——
   这正是本轮定位的起点。
3. **`--single-process` 的 rc=191 是"子进程初始化逻辑跑在 browser 内"的指纹**，
   而不是"这个模式被 Chromium 自己禁掉了"。它其实是一个免费的**独立 A/B 探针**。
4. **console 只保留 tail**：guest 内 `/root/` 是真实磁盘 → 必须 `debugfs dump` 出来看完整日志
   （本轮 336 行 vs console 里的 120 行窗口，信息量差一个数量级）。
   工具：`scripts/t490/pull_guest_logs.sh`（新增，QEMU 停机后执行）。
5. **`autorun` 里的探针循环是固定列表**，新探针必须同步加进去（P2 轮白跑过一轮）；
   本轮 `autorun_install.sh` 与 `autorun_nnp.sh` 都已加入 `/nvprobe`。
6. **前台 `sleep` 会撞 Bash 工具超时**：窥探远端进度时不要用 `sleep N`，直接读增量文件。
7. **Windows OpenSSH 的 `scp` 不处理含中文的绝对目标路径**（`/e/…/中电杯/…` 会被
   UTF-8 转义成 `\344\270\255…` 而报 No such file）。
   绕过：先 `cd` 进目标目录再用**相对路径**。
