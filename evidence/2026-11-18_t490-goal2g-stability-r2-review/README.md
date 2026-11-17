# stability-r2 复核补充

r2 使用轻量 observer6 与每 5 秒 family snapshot，Weston/Browser watchdog 持续存活，family 行能记录 Browser、Zygote 子进程和 Zygote 子进程候选；但官方首页仍没有 strict PASS。driver 在 2400 秒 readiness deadline 写出 `STABILITY_DRIVER_FAIL initial strict page gate timed out`，QEMU 随后正常退出。72 张截图全部严格失败，reload_count=0，page_ready 与 monitor_end 缺失，30 分钟计时没有开始。

该结果排除了“只有 MP_LEDGER=1 才会卡住”的单一解释。r3 将保持轻量 observer 与进程快照，只改变初始页 QMP 截图轮询：从每 5 秒改为每 30 秒，reload 检查仍每 5 秒。该变量用于检查高频 screendump 是否影响 bootstrap，尚未实测。

原始 73 张 PPM 保留在 T490 的 `/home/mo/xk6/evidence/2026-11-18_t490-goal2g-stability-r2/`；哈希见 `source-ppm-sha256.txt`。本目录的 PNG 只供查看，不替代源 PPM。
