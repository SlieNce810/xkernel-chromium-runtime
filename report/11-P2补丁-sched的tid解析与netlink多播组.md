# P2 补丁：sched 的 tid 解析 + netlink 多播组 bind（附 renderer 阻塞的排除性证据）

> 编制：小格（赛题六 · 兼容性缺口与补丁）· 2026-09-21
> 上游：`https://gitee.com/openkylin/x-kernel.git` · 平台：T490 原生 Ubuntu 26.04 · QEMU 10.2.1 · **纯 TCG**
> 先前：`report/09-…G4…`（unix stream SCM_RIGHTS 已修）· `report/10-Chromium推进与剩余阻塞.md`
> 证据：`evidence/2026-09-21_t490-{p2,child,child2}/`

---

## 1. 一句话结论

**两处兼容性缺陷已修复，并用专用探针直接验证通过（`ALL_PASS`）。**
但二者都不足以让 Chromium 的 renderer/utility 子进程活下来 ——
本轮已**排除**了"子进程启动通路有问题"这一大类假设（fork / execve / `/proc/self/exe` 全部正常）。

---

## 2. 缺陷 1：`sched_getparam` 只按 tgid 解析，非主线程必得 ESRCH

### 2.1 现象
Chromium 的 absl 在加锁路径上反复报：
```
[mutex.cc : 956] RAW: pthread_getschedparam failed: 3      ← ESRCH
```

### 2.2 根因（源码级）
musl 的 `pthread_getschedparam` 传的是**目标线程的内核 tid**：
```c
int pthread_getschedparam(pthread_t t, int *policy, struct sched_param *param)
{
    int r = __syscall(SYS_sched_getparam, t->tid, param);   // ← 是 tid，不是 pid
```

而 `core/ksyscall/src/task/sched.rs` 里：
```rust
fn scheduler_target(pid: i32) -> KResult<ktask::KtaskRef> {
    kprocess::scheduler::target_task(pid)      // ← 只走这条
}
```
`kprocess::scheduler::target_task()` 是"**按 tgid 找进程、再取代表线程**"：
```rust
let process = lookup::live_process(pid)?;      // 按 tgid 查
representative_task(process.as_ref())
```
于是任何**非主线程**（tid ≠ tgid）调用 `pthread_getschedparam` → `live_process(tid)` 查不到 → **ESRCH(3)**。

> 同一个文件里的 `affinity_target()` **已经**做了 tid 优先 + 进程回退，注释还明确写着
> *"Linux accepts a tid here (pthread_setaffinity_np). Fall back to the process-leader lookup
> used by other sched_\* syscalls."* —— 说明"sched_\* 只认 tgid"是**已知取舍**，
> 但对 `sched_getparam` 而言它造成了真实故障。

### 2.3 修法
让 `scheduler_target()` 与 `affinity_target()` 语义一致：**tid 优先，失败再回退到进程查找**。

```rust
fn scheduler_target(pid: i32) -> KResult<ktask::KtaskRef> {
    if pid < 0 { return Err(KError::NoSuchProcess); }
    if pid == 0 { return Ok(current().clone()); }
    match kprocess::scheduler::task_by_tid(pid as u32) {
        Ok(task) => Ok(task),
        Err(_) => kprocess::scheduler::target_task(pid),
    }
}
```
另加 2 个单测：`scheduler_target_resolves_the_caller_and_its_own_tid`、
`scheduler_target_rejects_unknown_ids`。

---

## 3. 缺陷 2：NETLINK_ROUTE 带多播组就 bind 失败

### 3.1 现象
```
ERROR:net/base/address_tracker_linux.cc:243] Could not bind NETLINK socket: Not supported (95)
```
（`AddressTrackerLinux` 是 Chromium 网络服务启动时的必经组件。）

### 3.2 根因（源码级）
`net/knet/src/netlink/socket.rs::bind()`：
```rust
fn bind(&self, local_addr: SocketAddrEx) -> KResult {
    let addr = local_addr.into_netlink()?;
    if self.inner.protocol == NETLINK_ROUTE && addr.groups != 0 {
        return Err(LinuxError::EOPNOTSUPP.into());      // ← 直接打回
    }
    ...
}
```
Chromium **无条件**用 `nl_groups` 订阅路由变化（`RTMGRP_IPV4_IFADDR | RTMGRP_IPV4_ROUTE` 之类），
于是 bind 必然失败。Linux 上这是合法且标准的用法。

### 3.3 修法
**接受**带 groups 的 bind，照常记录到 `local_addr`：

```rust
// Multicast group membership is recorded but not delivered yet: the only
// publisher today is kobject-uevent (`update_uevent_subscription` returns
// early for every other protocol), so a NETLINK_ROUTE socket that joins
// RTMGRP_* groups binds successfully and simply never observes route
// notifications. ... TODO: publish RTMGRP_* notifications once the routing
// table can change at runtime.
*self.inner.local_addr.write() = Some(addr);
self.update_uevent_subscription(addr);
self.inner.poll_rx.wake();
Ok(())
```
> 语义说明（诚实标注）：本补丁只让 **bind 成功**，**不投递** RTMGRP_\* 通知。
> 在静态网络配置的 guest 里，"路由表从不变化"与"收不到通知"等价，因此行为可接受；
> 已在代码注释里留 TODO。若上游要求完整语义，需要补 rtnetlink 的通知发布路径。

---

## 4. 验收：专用探针直接验证（`scripts/t490/p2probe.c`）

不依赖 Chromium 日志推断，直接调 syscall / libc：

```
[ENV] pid=75 tid=75
[SCHED] sched_getparam(pid=0) -> 0 errno=0                     ← 对照
[SCHED] 子线程: gettid=77 getpid=75                            ← 真子线程，tid != pid
[SCHED] raw sched_getparam(tid=77) -> 0 errno=0                ← 补丁前应为 ESRCH=3
[SCHED] raw sched_getscheduler(tid=77) -> 0 errno=0
[SCHED] pthread_getschedparam(pthread_self()) -> rc=0 policy=0 ← absl/Chromium 实际走的路径
[NETLINK] groups=0 对照: bind(fd=3, nl_groups=0x0) -> 0 errno=0
[NETLINK] groups!=0 目标: bind(fd=3, nl_groups=0xd) -> 0 errno=0 ← 补丁前应为 EOPNOTSUPP=95
[RESULT] fail=0
[RESULT] ALL_PASS — P2 两处修复均生效
```

**副产物确认**：Chromium 日志中 `[mutex.cc : 956] RAW: pthread_getschedparam failed: 3` **已消失**。

构建：`make build` → **BUILD_EXIT=0**（`Built …/kplat-aarch64/release`）
改动量：`core/ksyscall/src/task/sched.rs` **+37**、`net/knet/src/netlink/socket.rs` **+13**
应用器：`scripts/t490/p2_sched_netlink.py`（精确匹配 / 幂等 / 不盲改）

---

## 5. 但 renderer 仍未起来 —— 本轮排除了什么

### 5.1 仍未解决
- browser 进程常驻（PID 179）、窗口能出，但 **`renderer` 始终为空**；
- `Network service crashed or was terminated, restarting service.` **仍在每 ~5 s 循环**（未消除）。

> ⚠️ **方法教训**：我第一次判定"崩溃循环消失"是**只看 console 最后 120 行窗口**看漏了。
> 判断"某类日志是否消失"**必须全局 grep 计数**，不能看 tail 窗口。

### 5.2 本轮排除的假设（都有证据）

| 假设 | 结论 | 证据 |
|---|---|---|
| popen/fork 本身有问题 | ❌ 排除 | `childprobe` C2 PASS |
| `execve` 有问题 | ❌ 排除 | C4（绝对路径）、C5（`/bin/busybox`）PASS |
| **`/proc/self/exe` 不可用**（Chromium 靠它定位自身） | ❌ 排除 | C1 `readlink → "/childprobe"`；C3 **fork + `execve("/proc/self/exe","--child")` → code=0** 全 PASS |
| 内核 panic / trap / OOM 导致子进程死 | ❌ 排除 | console 全局 grep 无 panic/trap/fault/OOM |
| 未实现的 syscall 导致 | ⚠️ 只剩 1 个 | 全局统计只有 `landlock_create_ruleset`（2 次），非致命 |
| `/proc/self/exe` 未实现 | ❌ 排除 | `fs/filesystems/procfs/src/task_nodes/root.rs:830,889` 已实现 |
| `clone`/`clone3`/`execve` 未分发 | ❌ 排除 | 均在 `core/ksyscall/src/dispatch.rs`（555/563/520 行） |

### 5.3 关键新证据（指向下一步）
`/root/chromium.log` 里**只有 browser 自己的 PID**（`179:179` / `179:197` / `179:198`），
**子进程一行日志都没有** → 子进程在**能打日志之前**就死了（早于 `base::Logging` 初始化）。

---

## 6. 下一步：把子进程"单独跑起来"看它自己的报错

Chromium 的子进程就是同一个二进制加 `--type=` 参数，**可以手工启动**，从而直接看到它的 stderr：

```bash
# guest 内（XDG_RUNTIME_DIR/WAYLAND_DISPLAY 已在 autorun 中设好）
/usr/lib/chromium/chromium --type=utility \
  --utility-sub-type=network.mojom.NetworkService \
  --no-sandbox --disable-gpu --enable-logging=stderr --v=1 \
  --user-data-dir=/tmp/chromium-baseline 2>&1 | head -60
```
- 若它**立刻死且无输出** → 用 `echo $?` 看退出码；再用一个最小 C 探针复刻其"启动后第一件事"
  （候选：`memfd_create` / `madvise` / `futex` 变体 / `getrandom` / `seccomp`）。
- 若它**打印了错误** → 直接得到根因，按错误补内核。

> 注意：x-kernel **无 ptrace**（早前实测），所以 `strace` 在这个场景不可用，只能靠"手工启动 + 退出码"。

其次（优先级更低）：
- **`virtio-mouse` 未生成 evdev 节点（G6）**：已定位到**输入设备注册层** ——
  `io/inputdev/src/lib.rs::register_input_device()` 以 `handle.id()` 去重，
  而 `drivers/devices/virtio/src/input.rs::physical_location()` 对所有实例**硬编码返回
  `"virtio0/input0"`**。若 QEMU 的 virtio-keyboard 与 virtio-mouse 上报相同的
  `InputDeviceId`（vendor/product/version 相同），第二个设备会被**当作重复而静默丢弃** →
  只剩 `event0`。修法：把定位/唯一标识改为**按实例（如 PCI BDF）**，去重键也相应改。
- netlink RTMGRP_\* 的真实投递（见 §3.3 TODO）。

---

## 7. 复现

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel

# ① 打补丁 + 构建
python3 ~/xk6/scripts/t490/p2_sched_netlink.py ~/x-kernel
make build                      # 期望 BUILD_EXIT=0

# ② 验证（探针 + weston + chromium 一轮跑完）
cd ~/xk6
BASE_IMG=$HOME/x-kernel/images/pkg-installed.img \
PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh p2 700 150 autorun_install.sh p2probe.c childprobe.c

# ③ 看判定
D=~/xk6/evidence/$(date +%Y-%m-%d)_t490-p2
tr -d '\r' < $D/console.log | grep -nE "^\[SCHED\]|^\[NETLINK\]|^\[C[0-9]\]|CHILD_.*=|\] ALL_PASS|\] HAD_FAILURE"
```

**注意**：`autorun_install.sh` 的探针循环是**固定列表**（`/p2probe /childprobe /evprobe /fdprobe`），
新增探针必须同步加进去（本轮曾因此白跑一轮）。
