# R60：no-direct-PTE ERROR 候选冷启动复测 03

R60 与 R58、R59 完全重复同一诊断配置：no-direct-PTE、`LOG_LEVEL_ERROR` 候选内核，2 GiB AArch64 纯 TCG，Chromium 149.0.7827.53，2400 秒页面期限、一次真实 Ctrl+R 重载、420 秒保持；memory sampler、lifecycle preload、guest clock sync 均关闭。实际 QEMU 内核路径和运行配置 SHA-256 均与候选匹配：`c78ecd57fb47b8269ebecf0a4e99ee5d9f85648e01703726eee7af88ad017a67`。

guest 240 秒周期截图为启动期白屏；稳定性驱动捕获到初始严格页面并通过 7/7，guest 540 秒周期截图也通过 7/7。真实 Ctrl+R 后页面通过严格判据。驱动结果 `pass=1 duration=420.0 reloads=1/1`，事件归一化 240/240 PASS，0 项修复，driver 和 round 均返回 0。formal gate 按 diagnostic-only 约定跳过（rc=78）。

本轮是有效冷启动诊断，不替代 30 分钟正式稳定性结果，也没有有效性能数据。guest 540 秒为周期截图采样上界，不是浏览器启动或首帧延迟指标。

原始 PPM 保留在 T490：`/home/mo/xk6/evidence/2026-11-21_t490-r60-error-cold03`。SHA-256 见 [R60 PPM 清单](../_ppm-sha256-r60-error-cold03.txt) 和 `ppm-sha256-all.txt`；仓库中保存 PNG 预览。完整干跑、命令、环境、构建指纹、事件和判据见本目录其他文件。

![R60 首屏通过](screenshots/shot-02-at0540s.png)

![R60 重载后通过](stability/load-01-reload.png)

详细分析见 [R60 冷启动报告](../../report/432-T490-R60候选内核cold-start复测-20261121.md)。
