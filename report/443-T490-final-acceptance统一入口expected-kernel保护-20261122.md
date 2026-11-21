# `final-acceptance.sh` 统一入口内核身份保护

R57 的路径误用证明，仅记录候选工作目录不足以证明 QEMU 实际加载了该 kernel。稳定性 runner 已支持 `KERNEL_DIR` 解析/导出及可选的 `STABILITY_EXPECTED_KERNEL_SHA256` 启动前校验。本轮又在 `scripts/final-acceptance.sh` 增加 `T490_EXPECTED_KERNEL_SHA256`：

- 在 `cmd.txt`、`env.txt` 记录 expected hash；
- 拒绝非 64 位十六进制值；
- 将合法值转发成远端 `STABILITY_EXPECTED_KERNEL_SHA256`，供 stability runner 在 QEMU 前比对实际 kernel binary。

T490 preflight 使用 `/home/mo/xk6/worktrees/r64-targeted-scm-no-direct` 与 `a70ecb4a…`：`bash -n`、help、`all` 全阶段 dry-run、stability dry-run通过；all dry-run 显示 `NOT_RUN/20`、`ACCEPTANCE_RC=0` 且没有启动QEMU；坏 hash 在远端 stage 前被拒绝。完整归档见 [preflight evidence](../evidence/2026-11-22_t490-final-acceptance-wiring-preflight/README.md)。
