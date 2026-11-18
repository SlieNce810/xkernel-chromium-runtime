# SCM_RIGHTS stream short-read WSL2 Linux baseline 与 T490 对照待补

## 结论

新增的 `compatprobe --scm-rights-shortread` 在 WSL2 Linux 5.15.167.4 / x86_64 上通过 6/6 检查。Linux 在 AF_UNIX `SOCK_STREAM` 发送 100 字节数据和一个 `SCM_RIGHTS` fd 后，把 descriptor 随第一个 1 字节 `recvmsg` 交付；后续 99 次一字节读取不再重复交 fd，数据内容完整。

这只是 Linux 参考结果，不是 T490 native Linux/x86_64 或冻结版本 x-kernel/AArch64 guest 结果，也没有关闭 Chromium Mojo 页面回归。T490 当前仍不可达，report286 中 short-read 兼容性条目保持待完成。

## 复现

```bash
gcc -O2 -Wall -Wextra -Werror -o tmp/compatprobe-linux scripts/t490/compatprobe.c
tmp/compatprobe-linux --scm-rights-shortread
```

同一源码的 T490 guest 入口已加入 `autorun_scm_rights_shortread.sh`。T490 恢复后应先以本机 Linux 编译运行作为 native 对照，再将同一源码交叉编译进 QEMU guest，并保存 host/guest 的 compiler、source hash、kernel hash 与原始输出。

| 检查 | WSL2 Linux 结果 |
|---|---|
| `socketpair(AF_UNIX, SOCK_STREAM)` | PASS |
| 100 字节发送并附带一个 `SCM_RIGHTS` fd | PASS |
| 第一个 1-byte `recvmsg` 收到一个 fd | PASS |
| 后续 99 次 1-byte `recvmsg` 不重复 fd | PASS |
| 完整 100-byte stream payload | PASS |

完整 stdout、命令、环境和 SHA-256 在 [WSL2 baseline evidence](../evidence/2026-11-19_wsl2-scm-rights-shortread-baseline-r1/)；探针源码与 guest autorun 见 `scripts/t490/compatprobe.c` 和 `scripts/t490/autorun_scm_rights_shortread.sh`。
