# T490 R73 c80 绝对 tablet 冷启动失败（2026-11-22）

## 结论

R73 在开始输入动作之前未达到严格的 interaction 页面首帧判据，按冷启动失败归档。它不是输入判据失败，也不计入三次成功冷启动或 Input 4/4。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 平台：2 GiB、AArch64 QEMU 纯 TCG、Weston 原生 Wayland、Chromium 149 默认多进程
- 输入设备：virtio keyboard、virtio mouse、virtio tablet
- 运行目录：`/home/mo/xk6/evidence/2026-11-22_t490-r73-c80-tablet-input02`
- 本地证据：`evidence/2026-11-22_t490-r73-c80-tablet-input02/`

## 观测

- 运行约 872 秒时，QEMU、Weston、Browser 和 renderer 仍存活。
- 周期截图持续为白色画面，最新严格判据为 2/4；失败项为 `official_banner` 和 `interaction_checks_table`，说明没有达到有效首帧。
- watchdog 没有报告进程退出或 Wayland 断连。
- 等待期间没有发送输入动作，因而没有生成可接纳的 input gate。
- QMP socket 在高负载时连接超时；随后以已记录的 QEMU PID 终止本轮并清理 runner，避免占用 T490 的 guest 内存。

## 与 R72 的关系

R72 使用同一候选内核、2 GiB 和 tablet 设备，曾到达严格页面并证明键盘/JS 真实输入可以工作，但鼠标按钮和 CSS 导航仍未通过。R73 在进入输入前就出现首帧缺失，因此不能用于判断 R72 的 0.50 秒绝对点击等待修复。下一轮需要重新获得严格首帧后再验证该时序修复。

## 证据

本地 bundle 保存命令、环境、构建清单、周期 PPM 的 SHA-256、PNG 预览、console、watchdog 和平台门禁结果；原始 PPM 继续保留在 T490。

