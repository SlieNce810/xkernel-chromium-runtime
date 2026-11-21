# R69：a70e compatibility 候选正式稳定性尝试 01（首屏超时）

R69 在 c80/a70e 候选 SHA `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f` 上执行 formal gate，2 GiB AArch64 pure TCG、Chromium 149.0.7827.53，2400 秒首屏期限、10 次真实重载计划（每 120 秒）、页面通过后 1805 秒保持计划。实际 QEMU `-kernel` 路径和 expected SHA 经现场核对一致。

guest 2400 秒内页面没有严格通过。73 张 periodic PPM 全是白帧，严格 0/73；`any_strict_pass=0`、`last_frame_strict_pass=0`。稳定性事件归一化 1079/1079 PASS，0 修复；期限末 Weston、Chromium 和 renderer 仍被观察为存活，没有 Wayland fatal。driver 报 initial strict page gate timeout（rc=1），没有进入 reload 或 hold；formal gate rc=1。失败完整记录保留，不从末端存活状态推断页面通过。

R69 采用 30 秒周期 screendump；R54 的正式通过配置用 1200 秒周期 screenshot、独立 30 秒进程/host liveness 观察。为减小画面采样负载，下一正式复跑将保持其他参数不变，把 `IVL` 改为 1200 秒；R69 仍作为本配置的正式失败样本。

原始 PPM 留在 T490，SHA-256 清单见 [R69 PPM 清单](../_ppm-sha256-r69-r64-compat-formal01.txt)。本地保存 PNG 预览、完整 console、每帧判据、QMP transcript、事件和稳定性 gate 结果。

精确运行设置、环境、命令与 kernel identity 在本目录；QEMU 命令/平台预检另见 [R69 preflight](../2026-11-22_t490-r69-r64-formal-preflight/README.md)。详细分析见 [R69 报告](../../report/442-T490-R69-a70e候选正式稳定性首屏超时-20261122.md)。
