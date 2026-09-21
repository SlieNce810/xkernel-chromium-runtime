#!/usr/bin/env python3
"""P3 补丁应用器 —— 让 prctl(PR_SET_NO_NEW_PRIVS) 具备真正的 Linux 语义。

背景（源码级，本补丁的立论依据）
--------------------------------
Chromium `base/process/launch_posix.cc` 在 **fork() 之后、execvp() 之前**执行：

    if (!options.allow_new_privs) {
      if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
        // EINVAL 表示内核 < 3.5 不支持；EPERM 表示环境自身限制（如系统强加 seccomp）
        if (errno != EINVAL && errno != EPERM) {
          RAW_LOG(FATAL, "prctl(PR_SET_NO_NEW_PRIVS) failed");
        }
      }
    }

而 x-kernel `core/ksyscall/src/task/ctl.rs` 对该 option **无条件返回 ENOSYS(38)**。
38 既不是 EINVAL(22) 也不是 EPERM(1) → 命中 `RAW_LOG(FATAL)` → 子进程在 exec **之前**就 abort。

实际表现（2026-09-21 T490 实测）：
- 浏览器日志里每条 `Network service crashed or was terminated` 紧跟着一行
  **无 `[pid:tid:...]` 前缀**的 `prctl(PR_SET_NO_NEW_PRIVS) failed`（1:1 对应）；
  无前缀正是因为它在 fork 后、Chromium 日志前缀机制之外，由子进程直接写共享 stderr。
- 每个子进程（network service / GPU / renderer / utility）都在 exec 前死 → 子进程零输出、
  renderer 永远为空、`--single-process` 也一样死（子进程初始化跑在 browser 内，同一条路）。

修法
----
`UserThread::set_no_new_privileges()` 早已存在（`process/kprocess/src/thread/core.rs`），
且 fork/clone 的**继承路径也已实现**（`prepare_process_fork` / `prepare_thread_clone`
都把 `self.no_new_privileges()` 传给子线程）。所以本补丁只是把这一臂从"拒绝"改成
"接受并记录"，让 PR_SET/PR_GET 形成闭环。

**这不是桩，是正确语义**：x-kernel 没有 setuid/文件能力带来的特权提升路径，
"execve 不会授予原本没有的权限"这句承诺在此天然成立；返回 0 与 Linux 3.5+ 一致。
（顺带：即便只回 EINVAL 也能让 Chromium 容忍——但那是"骗过调用方"，本补丁给真语义。）

用法：
    python3 p3_prctl_nonewprivs.py ~/x-kernel
特性：精确匹配 / 幂等 / 不盲改；每处改动都要求 old 串**恰好出现一次**。
"""

import re
import sys
from pathlib import Path

CTL = "core/ksyscall/src/task/ctl.rs"

# ---------------------------------------------------------------- 改动 1：syscall 本体
OLD_ARM = """        PR_SET_NO_NEW_PRIVS => {
            if arg2 != 1 || arg3 != 0 || arg4 != 0 || arg5 != 0 {
                return Err(KError::InvalidInput);
            }
            return Err(KError::from(LinuxError::ENOSYS));
        }
"""

NEW_ARM = """        PR_SET_NO_NEW_PRIVS => {
            // Linux 3.5+: record the sticky "no privilege gain on execve" flag and
            // return 0. The attribute is inherited across fork/clone (see
            // `Thread::prepare_process_fork` / `prepare_thread_clone`) and cannot be
            // unset, so this is a one-way latch.
            //
            // Refusing with ENOSYS here is NOT compatible: user space is entitled to
            // probe with EINVAL/EPERM (see chromium base/process/launch_posix.cc),
            // and an unexpected errno turns a best-effort hardening step into a
            // fatal one — every Chromium child aborts right after fork(), before
            // execvp(), which is why the browser could never spawn a renderer.
            if arg2 != 1 || arg3 != 0 || arg4 != 0 || arg5 != 0 {
                return Err(KError::InvalidInput);
            }
            kprocess::current_user_thread().set_no_new_privileges();
        }
"""

# ---------------------------------------------------------------- 改动 2/3：导入清理
OLD_IMPORT = "use kerrno::{KError, KResult, LinuxError};\n"
NEW_IMPORT = "use kerrno::{KError, KResult};\n"

OLD_TEST_IMPORT = "    use kerrno::{KError, LinuxError};\n"
NEW_TEST_IMPORT = "    use kerrno::KError;\n"

# ---------------------------------------------------------------- 改动 4：单测改写
OLD_TEST = """    #[def_test(user, serial)]
    fn prctl_set_no_new_privs_requires_exec_enforcement() {
        assert_eq!(
            sys_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0),
            Err(KError::from(LinuxError::ENOSYS))
        );
    }
"""

NEW_TEST = """    // NOTE: the no_new_privs latch cannot be cleared, so this test is
    // order-sensitive — it must stay *after* `prctl_get_no_new_privs_reports_unset`,
    // which asserts the pristine value, and `def_test(..., serial)` keeps the
    // declared order. Argument validation is checked first so the failing branch
    // never latches the flag.
    #[def_test(user, serial)]
    fn prctl_set_no_new_privs_latches_and_reads_back() {
        assert_eq!(
            sys_prctl(PR_SET_NO_NEW_PRIVS, 0, 0, 0, 0),
            Err(KError::InvalidInput)
        );
        assert_eq!(sys_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), Ok(0));
        assert_eq!(sys_prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0), Ok(1));
        // Sticky: a second set stays Ok(0) and never regresses.
        assert_eq!(sys_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), Ok(0));
        assert_eq!(sys_prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0), Ok(1));
    }
"""

EDITS = [
    (OLD_ARM, NEW_ARM, "PR_SET_NO_NEW_PRIVS 实现"),
    (OLD_IMPORT, NEW_IMPORT, "模块级导入去掉 LinuxError"),
    (OLD_TEST_IMPORT, NEW_TEST_IMPORT, "测试模块导入去掉 LinuxError"),
    (OLD_TEST, NEW_TEST, "单测改为 latch 往返"),
]


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: p3_prctl_nonewprivs.py <x-kernel 路径>")
        return 2
    root = Path(sys.argv[1]).expanduser().resolve()
    path = root / CTL
    if not path.is_file():
        print(f"!! 找不到 {path}")
        return 1

    text = path.read_text(encoding="utf-8")

    if "set_no_new_privileges()" in text:
        print("[skip] 已应用（源码里已存在 set_no_new_privileges() 调用）")
        return 0

    original = text
    applied = []
    for old, new, label in EDITS:
        n = text.count(old)
        if n != 1:
            # 允许"已经是对的"这种情况：串不存在但目标形态已在
            if n == 0 and new in text:
                print(f"[skip] {label}: 目标形态已存在")
                continue
            print(f"!! {label}: 期望匹配 1 次，实际 {n} 次 —— 拒绝盲改")
            return 1
        text = text.replace(old, new, 1)
        applied.append(label)

    if text == original:
        print("[skip] 无变化")
        return 0

    path.write_text(text, encoding="utf-8")

    added = len(text.splitlines()) - len(original.splitlines())
    print(f"[ok] {CTL}: 行数变化 {added:+d}")
    for label in applied:
        print(f"     - {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
