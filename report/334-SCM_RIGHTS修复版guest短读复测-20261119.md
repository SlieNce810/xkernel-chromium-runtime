# SCM_RIGHTS 修复版 guest 短读复测（2026-11-19）

## 结论

在隔离的 T490 AArch64 kernel worktree 中应用 [report 333](333-SCM_RIGHTS首字节交付候选补丁与T490流回归-20261119.md) 的首字节交付补丁后，用原 `compatprobe --scm-rights-shortread` 重跑 2 GiB pure-TCG guest，SCM_RIGHTS 项通过 6/6：fd 随首个 1-byte `recvmsg` 交付，后续读取不重复，100-byte payload 完整。原 frozen guest 同一探针为 4/6，因此该兼容差异在候选内核的 focused C 回归中已修复。

这个结果关闭的是 AF_UNIX stream short-read 的内核探针回归。Chromium Mojo 实际 IPC 页面回归仍未完成，故浏览器兼容矩阵的 SCM_RIGHTS 端到端条款继续保持待验。

## 运行身份与证据

T490 为 Ubuntu 26.04.1 / Linux `7.0.0-43-generic` / x86_64，QEMU 10.2.1。guest 为 AArch64、纯 TCG、2 GiB、四 vCPU，平台静态合规门禁 15/15 PASS。`KERNEL_DIR` 指向 `/home/mo/xk6/worktrees/xk-compat-fix-r1`；其 HEAD 为 `b73e5814087c9d33c5f0a35b66cc56be689d3dee`，保留 53 个原有 dirty files，并在隔离副本应用两份候选 patch。kernel binary SHA-256 为 `e218da29cd33538548d703de92752e63cf8ae528ec191ab78254f10418325dc9`。

运行窗口为 303.3 秒，QEMU 会话正常结束，外层 rc 0；兼容 bundle 的总 rc 为 1，因为 inotify 仍失败。修复候选在运行前先通过 `run-session.py --dry-run`，实际 QEMU 命令显示 2 GiB、纯 TCG、4 vCPU 和全部 virtio 设备，平台门禁 15/15 PASS；dry-run 记录见 [patched dry-run r1](../evidence/2026-11-19_t490-scm-patched-dryrun-r1/)。完整命令、T490 console、wrapper 日志、环境、源码/镜像/内核哈希、PPM 判据和远端 SHA-256 清单见 [patched C probe r1 evidence](../evidence/2026-11-19_t490-scm-patched-cprobe-r1/)。原始 PPM 仅保存在 T490；本地包含 SHA-256 清单和可查看 PNG 预览。

## 逐项对照

| 检查 | 修复前 x-kernel guest | 修复后候选 guest | 结论 |
|---|---:|---:|---|
| `sendmsg` 发送 100 bytes + `SCM_RIGHTS` fd | PASS | PASS | 不变 |
| 首个 1-byte `recvmsg` 收到 fd | FAIL | PASS | 已修复 |
| 后续 1-byte 读取不重复 fd | FAIL | PASS | 已修复 |
| 完整 100-byte payload | PASS | PASS | 不变 |
| `--scm-rights-shortread` | 4/6 | 6/6 | focused C probe 通过 |
| `knet::unix::stream` AArch64 QEMU 单测 | 未运行 | 24/24 PASS | 独立机制回归通过 |

Linux 对照仍是 WSL2 与 T490 native Linux 6/6 PASS，见 [report 328](328-SCM_RIGHTS-stream-shortread-WSL2-Linux基线与T490待补-20261119.md) 和 [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md)。

## 同轮其他结果与限制

- timerfd focused probe：4/4 PASS。
- inotify focused probe：9 PASS / 1 FAIL，watched-directory create 事件仍未变成可 poll 的命名事件。
- procfs memory probe：`statm`/`VmRSS` 随触页与 unmap 变化；`smaps_rollup` 不存在，PSS/USS 为 `UNAVAILABLE`。
- 本轮不是浏览器 GUI、稳定性或性能测试。五张 QEMU PPM 为 640×480 且显示输出未启用，不能作为浏览器画面证据。

下一步完成 Chromium Mojo 回归；随后处理 inotify 命名 parent event 和 procfs PSS/USS，之后再进入四项性能采样。
