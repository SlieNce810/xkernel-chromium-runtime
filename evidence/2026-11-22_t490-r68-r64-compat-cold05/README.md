# R68：R64 compatibility 候选 cold-start repeat 03

R68 使用 R65/R66 同一 a70e kernel binary SHA `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`，2 GiB AArch64 pure TCG、Chromium 149.0.7827.53，2400 秒首屏期限、一次真实 Ctrl+R 和 420 秒诊断保持。QEMU 实际 `-kernel` 与 expected hash 完全匹配。

guest 240 秒周期截图为白色暖机帧（1/7）；stable driver 捕获的 initial page、真实 Ctrl+R reload 页面及 guest 540 秒周期截图均通过 official-index 严格判据 7/7。driver `pass=1 duration=420.0 reloads=1/1`，事件归一化 306/306 PASS、0 修复，driver/round 为 0；formal gate 因 diagnostic-only 跳过（rc=78）。保持期间 Weston、Chromium 与 renderer 进程存活，没有 Wayland reset。

R65/R66/R68 是同一二进制 SHA 和相同启动/观察参数的三次独立 cold-start 页面/重载短诊断通过。R67 用相同二进制在 2400 秒内页面超时，仍须作为可靠性失败保留；不能因三次通过而忽略这个反例。R68 不是正式 30 分钟验收，没有性能采样。

原始 PPM 留在 T490 `/home/mo/xk6/evidence/2026-11-22_t490-r68-r64-compat-cold05`，哈希在 [R68 PPM 清单](../_ppm-sha256-r68-r64-compat-cold05.txt)。PNG 预览：

![R68 初始严格通过](stability/load-00-initial.png)

![R68 重载后严格通过](stability/load-01-reload.png)

精确 kernel/hash 干跑、环境、命令、QMP/event 与判据均已归档。长稳定性见后续 formal run。
