# R48：stat 起始 tick 与 procfs RSS/PSS/USS smoke

R48 在冻结快照重建的隔离内核 worktree 上应用 `proc-stat-starttime.patch` 与四个 procfs 驻留页补丁。候选构建成功，ELF SHA-256 为 `95b02d5b…15667e7`，QEMU 实跑 kernel.bin SHA-256 为 `dacf1eec…7b585298`。客体为 T490、AArch64、2 GiB、4 vCPU、Cortex-A76、QEMU 10.2.1 pure TCG；平台断言 15/15。

smoke 通过：`/proc/stat` root 起始 tick 为 142，进程身份 `5-142` 与 child `11-183` 非零且和 CSV/events 一致；tree endpoint 8 次采样、16 行、0 missed；RSS/PSS/USS 均有数值，原始 CSV/events 被严格提取。根标准 `smaps_rollup` 为 RSS 560 kB、PSS 560 kB、USS 560 kB、Shared 0 kB。`Shared=0` 是合法测量值，当前提取器保留它；可选内核计时列显式标记 `UNAVAILABLE` 并留在 CSV 中，summary 将其标为不可用，不填零。

提取和 10 项 `test_extract_proc_tree_smoke` 回归通过；完整 `scripts/tests` Python suite 为 77/77。证据文件见 `memory-export/records-r48/`。QEMU 未运行 Weston/Chromium；截图显示 `Display output is not active.` 且为 640×480，因此本轮仅验证内核 procfs shell smoke，不计图形、功能、稳定性或正式性能通过，也不产生四指标正式样本。

R48 使用时的 smoke runner 哈希为 `687980a8…1002762a`；之后本地 repo 将 `bad_values` 改为拒绝空/非数字、允许合法的零 USS/PSS。此脚本差异不影响 R48（所有 CSV RSS/PSS/USS 都非零），下一轮先同步更新版本。

R48 证明了在同一冻结快照上应用 stat22 与驻留页补丁后，root/child 的进程身份和 RSS/PSS/USS smoke 可以被严格复核。真实 Chromium 树的 1 Hz、页面加载后 60 秒峰值窗口，以及 renderer-ready/first-frame 仍未验证。
