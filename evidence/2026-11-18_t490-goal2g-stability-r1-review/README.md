# stability-r1 复核补充

这次稳定性尝试在启动后的 2400 秒 readiness deadline 内始终没有出现 official-index strict PASS。driver 输出 `STABILITY_DRIVER_FAIL initial strict page gate timed out`；同轮 QEMU 在 2402 秒后正常退出。原始 `ppm-summary.txt` 汇总为 72/72 张截图严格集未通过、`page_fail=1`、最终帧未通过；没有 page_ready、没有开始 30 分钟稳定计时，也没有触发真实 Ctrl+R 重载。

期间 guest watchdog 多次报告 Weston=yes、chrome=yes。Chromium 读取到指定 index 文件，但没有 DocumentLoader/DidCommitNavigation，截图保持空白。此轮不计稳定性 PASS。下一轮将改用轻量 Browser/Zygote/Renderer 家族快照，避免每秒完整 procfs 账本影响 renderer bootstrap。

原始 PPM 共 73 张（72 张会话 screendump + 1 张 timeout 截图），均保留在 T490 的 `/home/mo/xk6/evidence/2026-11-18_t490-goal2g-stability-r1/`；SHA-256 清单在 `source-ppm-sha256.txt`。PNG 仅用于查看失败页面。
