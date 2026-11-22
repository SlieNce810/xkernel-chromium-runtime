# R65：R64 targeted-SCM 候选 Chromium 冷启动

R65 使用 R64 focused compatibility 通过内核 SHA-256 `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`，2 GiB AArch64 pure TCG、Chromium 149.0.7827.53；启动前干跑和实际 QEMU `-kernel` 路径均匹配该 SHA。

guest 240 秒周期截图是白色暖机帧（严格 1/7）；稳定性驱动随后捕获的初始页面通过 7/7，guest 540 秒周期截图也通过 7/7。真实 Ctrl+R 重载后的页面通过严格判据。driver 报告 `pass=1 duration=420.0 reloads=1/1`；事件归一化 304/304 PASS、0 修复，driver/round 均返回 0。formal gate 因 diagnostic-only 跳过（rc=78）。这轮未复现 R63 的 Wayland reset。

R65 是 R64 内核的首个 Chromium 页面/重载通过诊断样本，不是 30 分钟正式稳定性或性能轮。540 秒只是周期截图上界；memory sampler、lifecycle preload 和 guest clock sync 均关闭。

原始 PPM 保留在 T490 `/home/mo/xk6/evidence/2026-11-22_t490-r65-r64-compat-cold02`，SHA-256 在 [R65 PPM 清单](../_ppm-sha256-r65-r64-compat-cold02.txt)。仓库 PNG 预览：

启动前精确内核路径/哈希干跑保存在 `preflight-dry-run.txt`，结果为 `qemu_started=0`。

![R65 首屏严格通过](screenshots/shot-02-at0540s.png)

![R65 重载后严格通过](stability/load-01-reload.png)

R63 同一 tracked source diff/config 的另一个构建 hash `12c0e795…` 曾在 110 秒遇到 fatal Wayland reset；R65 `a70ecb4a…` 通过但首帧启动阶段出现暖机白帧。两轮均保留，尚不足以断定差异来自二进制内容或间歇性因素。详见 [R65 报告](../../report/438-T490-R65-targeted-SCM兼容候选页面通过-20261122.md)。
