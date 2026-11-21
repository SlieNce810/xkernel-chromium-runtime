# R57：候选内核路径配置错误，轮次作废

R57 按 2 GiB、AArch64 纯 TCG、Chromium 149 参数启动，但实际 QEMU 加载了冻结目录 `/home/mo/x-kernel` 的内核 `51c4028594e4aff9fc5b9964c4294a2904621c93e84093ac711858c454aed284`，而本轮目标候选内核应为 `/home/mo/xk6/worktrees/r53-no-direct-error-log` 中的 `c78ecd57fb47b8269ebecf0a4e99ee5d9f85648e01703726eee7af88ad017a67`。

原因是稳定性脚本调用 `t490_round.sh` 时没有显式解析、导出和记录 `KERNEL_DIR`；仅在候选工作树执行外层脚本并不会改变子脚本默认的 `$HOME/x-kernel`。发现实际 QEMU 命令后，已停止该轮。运行约 190 秒，未获得严格页面判据、有效截图、重载或保持结果；本轮不计入候选内核冷启动/稳定性样本。

完整原始会话记录保留在本目录。`cmd.txt`、`build-manifest.txt` 和 `platform-compliance.txt` 可复核实际内核路径、SHA-256 与平台参数。QEMU 退出时稳定性驱动报告 `Broken pipe`，这是人为停止错误配置轮次的结果。

已在 [R57 路径问题报告](../../report/429-T490-R57候选内核路径配置错误-20261121.md) 记录原因和修复。稳定性入口现会解析并导出 `KERNEL_DIR`、记录内核文件路径和 SHA-256，并支持 `STABILITY_EXPECTED_KERNEL_SHA256` 在启动前阻止哈希不匹配。下一轮只在干跑确认内核路径与哈希后启动。
