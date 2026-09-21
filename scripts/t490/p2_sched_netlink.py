#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P2 补丁：两处兼容性缺陷修复（Chromium renderer 阻塞项的前置）

背景（2026-09-21 T490 实测，见 report/10-Chromium推进与剩余阻塞.md §3.2）
--------------------------------------------------------------------
Chromium 149 在 x-kernel 上 browser 进程能起、窗口能出，但 **renderer 子进程从未启动**，
日志每 ~5 s 循环：

    ERROR:...network_service_instance_impl.cc:722] Network service crashed or was terminated, restarting service.
    prctl(PR_SET_NO_NEW_PRIVS) failed
    [mutex.cc : 956] RAW: pthread_getschedparam failed: 3 (ESRCH)

两处独立缺陷：

【缺陷 1】`sched_getparam` / `sched_getscheduler` 只按 **tgid** 解析目标
    `core/ksyscall/src/task/sched.rs::scheduler_target()` 直接调
    `kprocess::scheduler::target_task(pid)`，而该函数是"按进程 id 找进程再取代表线程"：
        let process = lookup::live_process(pid)?;   // 按 tgid 查
        representative_task(process.as_ref())
    musl 的 `pthread_getschedparam` 传的是**目标线程的内核 tid**：
        __syscall(SYS_sched_getparam, t->tid, param);
    于是任何**非主线程**调用 `pthread_getschedparam` 都会走到 `live_process(tid)` 失败
    → ESRCH(3)。这正好解释了 absl 的 `[mutex.cc : 956] RAW: pthread_getschedparam failed: 3`。

    注意同文件的 `affinity_target()` **已经**做了 tid 优先 + 进程回退的正确处理
    （注释还写着 "Linux accepts a tid here (pthread_setaffinity_np). Fall back to the
    process-leader lookup used by other sched_* syscalls."）—— 也就是说其他 sched_* 的
    进程回退是**已知取舍**，但对 getparam 而言它造成了真实故障。
    修法：让 `scheduler_target()` 也 tid 优先、进程回退。

【缺陷 2】NETLINK_ROUTE socket 只要 `nl_groups != 0` 就 bind 失败
    `net/knet/src/netlink/socket.rs::bind()`:
        if self.inner.protocol == NETLINK_ROUTE && addr.groups != 0 {
            return Err(LinuxError::EOPNOTSUPP.into());
        }
    Chromium 的 `AddressTrackerLinux` 无条件用 `nl_groups`（RTMGRP_IPV4_IFADDR|RTMGRP_IPV4_ROUTE
    等）订阅路由变化，于是 bind 直接拿到 EOPNOTSUPP(95)：
        ERROR:net/base/address_tracker_linux.cc:243] Could not bind NETLINK socket: Not supported (95)
    修法：**接受**带 groups 的 bind 并照常记录到 `local_addr`。
    组播投递目前只有 kobject-uevent 一条通路（`update_uevent_subscription` 对
    NETLINK_ROUTE 早退），所以 RTMGRP_* 订阅者暂时收不到通知——这在静态网络配置的
    VM 里与"路由表从不变化"等价，行为可接受；已按 TODO 注明。

用法
----
    python3 p2_sched_netlink.py <x-kernel 根目录>

行为：逐个锚点精确匹配替换；已打过则跳过；匹配数 != 1 则报错退出（不盲改）。
"""

import os
import sys

SCHED_RS = "core/ksyscall/src/task/sched.rs"
NETLINK_RS = "net/knet/src/netlink/socket.rs"

# ---------------------------------------------------------------- 缺陷 1

SCHED_TARGET_OLD = """fn scheduler_target(pid: i32) -> KResult<ktask::KtaskRef> {
    kprocess::scheduler::target_task(pid)
}
"""

SCHED_TARGET_NEW = """/// Resolves the `pid` argument shared by the `sched_*` syscalls.
///
/// Callers may pass either a process id (tgid) or a thread id (tid): musl's
/// `pthread_getschedparam` forwards the *target thread's kernel tid*, so
/// resolving process leaders only makes every call on a secondary thread fail
/// with ESRCH. Try the tid first and fall back to the process-leader lookup,
/// mirroring [`affinity_target`].
fn scheduler_target(pid: i32) -> KResult<ktask::KtaskRef> {
    if pid < 0 {
        return Err(KError::NoSuchProcess);
    }
    if pid == 0 {
        return Ok(current().clone());
    }
    match kprocess::scheduler::task_by_tid(pid as u32) {
        Ok(task) => Ok(task),
        Err(_) => kprocess::scheduler::target_task(pid),
    }
}
"""

SCHED_TESTS_IMPORT_OLD = """    use super::{
        affinity_target, check_affinity_permission, check_setpriority_permission,
        prepare_setaffinity_target,
    };
"""

SCHED_TESTS_IMPORT_NEW = """    use super::{
        affinity_target, check_affinity_permission, check_setpriority_permission,
        prepare_setaffinity_target, scheduler_target,
    };
"""

SCHED_TESTS_ANCHOR_OLD = """        assert!(
            check_setpriority_permission(
                &Cred::root(),
                &target,
                NiceValue::new_clamped(5),
                NiceValue::DEFAULT,
            )
            .is_ok()
        );
    }
}
"""

SCHED_TESTS_ANCHOR_NEW = """        assert!(
            check_setpriority_permission(
                &Cred::root(),
                &target,
                NiceValue::new_clamped(5),
                NiceValue::DEFAULT,
            )
            .is_ok()
        );
    }

    #[def_test(user, serial)]
    fn scheduler_target_resolves_the_caller_and_its_own_tid() {
        let via_zero = scheduler_target(0).expect("pid 0 is the caller");
        assert!(current().ptr_eq(&via_zero));

        // musl's pthread_getschedparam passes the target thread's kernel tid.
        let tid = kprocess::current_user_tid() as i32;
        let via_tid = scheduler_target(tid).expect("caller tid must resolve");
        assert!(current().ptr_eq(&via_tid));
    }

    #[def_test]
    fn scheduler_target_rejects_unknown_ids() {
        assert_affinity_err(scheduler_target(-1), KError::NoSuchProcess);
        assert_affinity_err(scheduler_target(i32::MAX), KError::NoSuchProcess);
    }
}
"""

# ---------------------------------------------------------------- 缺陷 2

NETLINK_BIND_OLD = """    fn bind(&self, local_addr: SocketAddrEx) -> KResult {
        let addr = local_addr.into_netlink()?;
        if self.inner.protocol == NETLINK_ROUTE && addr.groups != 0 {
            return Err(LinuxError::EOPNOTSUPP.into());
        }
        *self.inner.local_addr.write() = Some(addr);
        self.update_uevent_subscription(addr);
        self.inner.poll_rx.wake();
        Ok(())
    }
"""

NETLINK_BIND_NEW = """    fn bind(&self, local_addr: SocketAddrEx) -> KResult {
        let addr = local_addr.into_netlink()?;
        // Multicast group membership is recorded but not delivered yet: the only
        // publisher today is kobject-uevent (`update_uevent_subscription` returns
        // early for every other protocol), so a NETLINK_ROUTE socket that joins
        // RTMGRP_* groups binds successfully and simply never observes route
        // notifications. Failing the bind with EOPNOTSUPP instead — as this used
        // to — breaks clients that subscribe unconditionally rather than probing
        // first; Chromium's `AddressTrackerLinux` is one of them and reports
        // "Could not bind NETLINK socket: Not supported (95)".
        // TODO: publish RTMGRP_* notifications once the routing table can change
        // at runtime.
        *self.inner.local_addr.write() = Some(addr);
        self.update_uevent_subscription(addr);
        self.inner.poll_rx.wake();
        Ok(())
    }
"""


def apply(path: str, label: str, old: str, new: str, failures: list) -> int:
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()

    if new in content:
        print(f"  [skip] {label}: already patched")
        return 0

    count = content.count(old)
    if count != 1:
        print(f"  [FAIL] {label}: expected exactly 1 occurrence, found {count}")
        failures.append(label)
        return 0

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content.replace(old, new, 1))
    print(f"  [ok]   {label}: replaced")
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = sys.argv[1]
    sched = os.path.join(root, SCHED_RS)
    netlink = os.path.join(root, NETLINK_RS)
    for p in (sched, netlink):
        if not os.path.isfile(p):
            print(f"[FAIL] not found: {p}")
            return 2

    failures = []
    changed = 0

    print(f"== {SCHED_RS} ==")
    changed += apply(sched, "scheduler_target: accept a tid (pthread_getschedparam)", SCHED_TARGET_OLD, SCHED_TARGET_NEW, failures)
    changed += apply(sched, "tests: import scheduler_target", SCHED_TESTS_IMPORT_OLD, SCHED_TESTS_IMPORT_NEW, failures)
    changed += apply(sched, "tests: add scheduler_target cases", SCHED_TESTS_ANCHOR_OLD, SCHED_TESTS_ANCHOR_NEW, failures)

    print(f"== {NETLINK_RS} ==")
    changed += apply(netlink, "bind(): accept nl_groups for NETLINK_ROUTE", NETLINK_BIND_OLD, NETLINK_BIND_NEW, failures)

    if failures:
        print(f"\n[FAIL] {len(failures)} anchor(s) not matched: {', '.join(failures)}")
        return 1

    print(f"\n[done] {changed} edit(s) applied (idempotent re-run reports skips).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
