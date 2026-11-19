# inotify 命名创建事件 guest 回归与 PSS 缺口（2026-11-19）

## 结论

在隔离的 T490 AArch64 2 GiB pure-TCG 候选内核上，原 `compatprobe.c --inotify-timerfd` 从 frozen guest 的 9/11 PASS、1 个 `poll(create)` 失败，提升为 timerfd/inotify 11/11 PASS；`inotify read matching IN_CREATE` 现在收到带正确 child name 的记录。SCM_RIGHTS 同轮 6/6 PASS。`procfs_memory_probe` 仍明确报告 `smaps_rollup`、PSS、USS unavailable，故这一轮不是兼容性总 PASS。

修复改动在 [inotify-named-child-events.patch](../patches/compat/inotify-named-child-events.patch)：队列改为可变长 `inotify_event`，创建操作向被 watch 的父目录 inode 发送含 NUL 终止文件名和 padding 的 `IN_CREATE`；文件写入/关闭也向父目录发送命名 `IN_MODIFY` / `IN_CLOSE_WRITE`。补丁覆盖 open(O_CREAT)、mkdir、mknod 以及现有写入/关闭路径。它尚未实现 rename/unlink 的全部事件组合，也未完成 Chromium watcher 页面回归。

## 对照与证据

Linux WSL2 与 T490 native Linux 的 focused 参考均通过，见 [report 327](327-inotify-timerfd-WSL2-Linux基线与T490待补-20261119.md) 和 [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md)。修复前 x-kernel 失败样本见 [report 332](332-T490-xkernel-inotify-scm-rights-procfs-probe-r1-20261119.md)。修复后，同一 C 源、同一 guest base image、同一 2 GiB QEMU 参数下得到 `inotify_timerfd 11/11`、`scm_rights_shortread 6/6`、bundle overall 0；完整 console、命令、环境、kernel/source hashes、timestamps、截图判据和 PPM 哈希见 [patched inotify C probe r1](../evidence/2026-11-19_t490-inotify-named-cprobe-r1/)。

候选 kernel worktree 是 `/home/mo/xk6/worktrees/xk-compat-fix-r1`，HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`，在 53 个既有 dirty 文件上增加了两份已单独验证的 patch；当前 dirty 文件数为 54。补丁前后均通过 `git apply --reverse --check` / `git apply --check`。原 `/home/mo/x-kernel` 未修改。单轮 wrapper 的 `KERNEL_DIR` 覆盖支持已加入仓库脚本，因此复现可在隔离 worktree 中进行；dry-run 15/15 平台门禁记录见 [patched dry-run r1](../evidence/2026-11-19_t490-scm-patched-dryrun-r1/)。

## 结果边界

这轮 5 分钟 compatibility session 不是浏览器 GUI、30 分钟稳定性或性能样本；QEMU screendump 为 640×480，画面显示 “Display output is not active.”。PSS/USS、共享页/COW 的精确归属依然不能从现有 `statm`/`VmRSS` 读数推导。后续需要补 `/proc/<pid>/smaps_rollup` 及真实共享驻留计数，并完成 Chromium inotify watcher 和 Mojo regressions。
