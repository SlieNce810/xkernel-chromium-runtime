# SCM_RIGHTS stream short-read WSL2 Linux baseline 与 T490 对照待补

## 结论

新增的 `compatprobe --scm-rights-shortread` 在 WSL2 Linux 5.15.167.4 / x86_64 上通过 6/6 检查。Linux 在 AF_UNIX `SOCK_STREAM` 发送 100 字节数据和一个 `SCM_RIGHTS` fd 后，把 descriptor 随第一个 1 字节 `recvmsg` 交付；后续 99 次一字节读取不再重复交 fd，数据内容完整。

这份 WSL2 结果只是补充 Linux 参考。随后同源 probe 在 T490 native Linux 7.0.0-43 上也通过 6/6，详见 [report 331](331-T490-native-Linux-compat-memory-reference-20261119.md)。2026-11-19 的 2 GiB AArch64 guest 对照中，sendmsg 与 100-byte payload 通过，但 fd 未随首个 1-byte recvmsg 交付，后续 read 又报告 fd，结果 4/6。隔离的 dirty source snapshot 上，候选补丁已令 `knet::unix::stream` QEMU 单测 24/24 通过；同一 C guest probe 和 Chromium Mojo 回归仍待执行，详见 [report 332](332-T490-xkernel-inotify-scm-rights-procfs-probe-r1-20261119.md) 和 [report 333](333-SCM_RIGHTS首字节交付候选补丁与T490流回归-20261119.md)。

## 复现

```bash
gcc -O2 -Wall -Wextra -Werror -o tmp/compatprobe-linux scripts/t490/compatprobe.c
tmp/compatprobe-linux --scm-rights-shortread
```

同一源码的 T490 guest 入口已加入 `autorun_scm_rights_shortread.sh`。原失败比较已保存 compiler/source/kernel hash 与原始输出。候选补丁和 stream 模块单测结果见 report 333；下一步要以补丁 kernel 重跑该 C guest probe 和 Mojo 回归。

| 检查 | WSL2 Linux 结果 |
|---|---|
| `socketpair(AF_UNIX, SOCK_STREAM)` | PASS |
| 100 字节发送并附带一个 `SCM_RIGHTS` fd | PASS |
| 第一个 1-byte `recvmsg` 收到一个 fd | PASS |
| 后续 99 次 1-byte `recvmsg` 不重复 fd | PASS |
| 完整 100-byte stream payload | PASS |

完整 stdout、命令、环境和 SHA-256 在 [WSL2 baseline evidence](../evidence/2026-11-19_wsl2-scm-rights-shortread-baseline-r1/)；探针源码与 guest autorun 见 `scripts/t490/compatprobe.c` 和 `scripts/t490/autorun_scm_rights_shortread.sh`。
