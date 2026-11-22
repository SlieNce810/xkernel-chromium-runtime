# T490 procfs 凭据修复与 Chromium sandbox SIGTRAP 定位（2026-11-17）

## 本轮结论

决赛浏览器功能评分仍为 20/20。原目标中的 renderer 原生 sandbox 尚未通过。本轮收敛出一个真实内核兼容缺口，并把 Chromium 的退出缩小到 zygote 初始化后的用户态异常。

## 凭据路径与修复

早期 headless 脚本把 `su nobody -s /bin/sh -c ...` 的分支日志误当成实际降权结果。调整为 BusyBox `su -s /bin/sh -c ... nobody` 后，在子进程内部读取 `id`，并在 UID 不等于 65534 时拒绝启动 Chromium。r6 的内核日志和 r8 的进程内记录均确认 `setuid/setgid(65534)` 成功。

r8 发现 `/proc/<pid>/status` 的 Uid/Gid 字段在 procfs 中被硬编码为 `0 0 0 0`，与 `getuid/getgid` 的结果不一致。这会向依赖 procfs 的程序报告错误的进程身份。`fs/filesystems/procfs/src/task_nodes/root.rs` 现从目标线程凭据生成 Uid、Gid 和 Groups。该版本纯 TCG 构建 SHA-256：

```text
ab089d09fa0c3fac1c88eea342a29a05d3e975011f9cef2f6303cecf647e2920
```

r8 子进程内证据确认 `id` 与 `/proc/self/status` 都返回 UID/GID 65534。内核随后处理了 user namespace clone 和 `uid_map/gid_map/setgroups` 文件访问，并启动 zygote。

## Chromium 退出边界

r8 的浏览器 PID 27 在 zygote 建立后以 133 退出，DOM 为 0。`libexittrace` 没有捕获该 PID 的 `exit`、`_exit`、`abort`、`kill` 或 `tgkill`；只捕获到一个 zygote 子进程 `_exit(0)`。x-kernel 将用户态 breakpoint 异常映射为 SIGTRAP，因此当前证据指向用户态同步异常；精确的异常类别、ESR 和指令地址仍待 r9 的 `USER_EXCEPTION_FATAL` 记录确认。

此次只增加异常日志，信号处理行为保持不变。包含该日志的内核构建 SHA-256：

```text
b3c664a057c29a718b49bfcd83cdf357b5ba0119c702d49b29d4985521e42482
```

r9 使用 Chromium 149、默认 zygote、无 `--no-sandbox`，已在 T490 纯 TCG 下完成。内核记录了：

```text
USER_EXCEPTION_FATAL pid=27 tid=27 kind=Breakpoint signo=SIGTRAP
  ip=0x901ee4c esr=0xf2000000 far=0x0ef10f4c
```

这将 133 的来源确认成 Chromium 主进程执行的用户态 breakpoint 异常；`libexittrace` 未记录 browser 自己调用退出或信号 API。r9 的页面 DOM 仍为 0，renderer sandbox 尚未初始化完成。

r10 在 browser 存活窗口采集了 `/proc/27/maps`。按主 ELF 的 load bias `0x10000` 还原后，`ip=0x901ee4c` 对应 Chromium 149 VMA `0x900ee4c`。同版本 debug package 的 build ID 与镜像中的 Chromium 一致；该地址的 AArch64 指令为 `brk #0`。

调用分支已对应到匹配源码 `sandbox/linux/services/namespace_sandbox.cc`：机器码在 `NamespaceSandbox::LaunchProcessWithOptions()` 的 `CHECK(clone_flags & CLONE_NEWUSER)` 冷分支。紧邻的 `tbz` 在标志位 28 未置位时跳转到该 BRK；Chromium 当时通过 `/proc/self/ns/user` 的 `PathExists()` 探测得到 false，所以未加入 `CLONE_NEWUSER`。此前 procfs 已有显示 `user:[id]` 的符号链接，但目标路径不存在，stat 跟随链接仍失败。

r12 为 namespace 链接目标补了可解析的 procfs 目标项。记录到 user、PID、network namespace 路径探测均为 present，随后 clone flags 包含 `CLONE_NEWUSER|CLONE_NEWPID|CLONE_NEWNET`，打开了 `uid_map` 并启动 zygote。对应证据：[2026-11-17_t490-sandbox149-ns-probe-r12](../evidence/2026-11-17_t490-sandbox149-ns-probe-r12)。这通过了 Chromium 的 namespace 能力探测，仍未代表 renderer sandbox 完成。

r12 的下一断点是 seccomp。Chromium 149 用空 `sock_fprog` 分别探测 `seccomp(...TSYNC, nullptr)` 和 `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, nullptr)`，Linux 约定两者都以 `EFAULT` 表示 syscall 可用。内核此前两者均返回 `EINVAL`。r13 已将 `seccomp(2)` 探测修为 `EFAULT`，但 Chromium 仍走 fallback 并报告不支持；日志显示 `prctl(option=22, mode=2, filter=null, trailing=100,99)` 被尾部参数校验拒绝。`PR_SET_SECCOMP` 同样需要对空 filter 返回 `EFAULT`，且忽略 ABI 未指定的尾部参数。

r14 已修复 `PR_SET_SECCOMP` 探测语义，seccomp syscall 与 prctl 两个空指针探测都返回 EFAULT。Chromium 随后越过了 PID namespace 的 `getpid()==1` 检查。r15 的符号映射进一步确认：此前 PID namespace 内 `getpid` 仍返回 root/global PID；为 clone、`getpid/getppid/gettid`、clone 返回值和 proc status 接入 `PidHandle::allocate_in()` 后，first process 的 PID namespace number 可成为 1。

r16 的 Chromium 149 继续进入 `Credentials::MoveToNewUserNS()`，在 `credentials.cc:340` 写嵌套 user namespace 的 UID/GID map 时返回 `EACCES`。原因是 x-kernel 的 `unshare(CLONE_NEWUSER)` 只更新 namespace proxy，没有给当前凭据安装新的 `UserNamespace`，所以 map 写入落到了已映射过的旧 namespace。该行为已修复为 `unshare(CLONE_NEWUSER)` 创建并提交新的子 user namespace，纯 TCG 内核构建 SHA-256：

```text
e2494a723b432f3af0aba3d742fc656b4bd78beb2eb5f868bc67561c31c3e1db
```

r17 将在不注入 exittrace 的条件下验证嵌套 user namespace 的 map 写入和接下来的 seccomp 过滤路径。当前 seccomp 非空 BPF program 仍未实现真实解释/执行；即使启动链继续，也不能把该诊断状态写成 sandbox PASS。

## 证据与日志收集

- r8 原始运行包：[2026-11-17_t490-sandbox149-procstatus-exittrace-r8](../evidence/2026-11-17_t490-sandbox149-procstatus-exittrace-r8)
- r8 补充 guest 日志：[2026-11-17_t490-sandbox149-procstatus-exittrace-r8-guestlog-supplement](../evidence/2026-11-17_t490-sandbox149-procstatus-exittrace-r8-guestlog-supplement)
- r9 运行包：[2026-11-17_t490-sandbox149-userexc-trace-r9](../evidence/2026-11-17_t490-sandbox149-userexc-trace-r9)
- r10 运行包：[2026-11-17_t490-sandbox149-userexc-maps-r10](../evidence/2026-11-17_t490-sandbox149-userexc-maps-r10)
- r11 运行包：[2026-11-17_t490-sandbox149-userexc-insn-r11](../evidence/2026-11-17_t490-sandbox149-userexc-insn-r11)
- r12 运行包：[2026-11-17_t490-sandbox149-ns-probe-r12](../evidence/2026-11-17_t490-sandbox149-ns-probe-r12)
- r13 运行包将保存在 `evidence/2026-11-17_t490-sandbox149-seccomp-probe-r13`。
- r14 运行包：[2026-11-17_t490-sandbox149-seccomp-probe-r14](../evidence/2026-11-17_t490-sandbox149-seccomp-probe-r14)
- r15 运行包：[2026-11-17_t490-sandbox149-seccomp-maps-r15](../evidence/2026-11-17_t490-sandbox149-seccomp-maps-r15)
- r16 运行包：[2026-11-17_t490-sandbox149-pidns-virtual-r16](../evidence/2026-11-17_t490-sandbox149-pidns-virtual-r16)

r8 的串口会话已正常结束，但自动 guest 日志回收在 20 秒内仍检测到 QEMU 占用工作镜像，导致 guest 目录为空。补充包在 QEMU 退出后从工作镜像只读提取日志，原始 r8 包未改写。`pull_guest_logs.sh` 已改为按命令行引用的镜像识别 QEMU，并等待最多 60 秒；这也避免误把其它 QEMU 当成本轮磁盘占用者。

## 未通过项与下一步

当前尚无 renderer sandbox 初始化成功、broker 连接或负向拒绝的证据。下一步修正 `PR_SET_SECCOMP` 空指针探测语义并重跑；非空 BPF program 当前仍未做完整过滤，不能据此标记 seccomp 或原生 sandbox PASS。sandbox gate 通过后继续做 30 分钟稳定性、guest RSS/PSS/USS、5 轮纯 TCG 性能统计和现场验收入口。
