# T490 R75 c80 绝对 tablet 首帧失败（2026-11-22）

## 结论

R75 使用自检按钮直接绝对点击和 15 秒 readiness settle 的新 runner，但完整 900 秒运行没有出现严格 interaction 首帧，未进入输入动作，归档为独立冷启动失败。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 平台：2 GiB、AArch64 QEMU 纯 TCG、Weston 原生 Wayland、Chromium 149 默认多进程
- 输入设备：virtio keyboard、virtio mouse、virtio tablet
- 运行目录：`/home/mo/xk6/evidence/2026-11-22_t490-r75-c80-tablet-input04`
- 本地证据：`evidence/2026-11-22_t490-r75-c80-tablet-input04/`

## 观测

- readiness 共记录 85 张截图，最新严格判据为 2/4；失败项为 `official_banner` 与 `interaction_checks_table`。
- watchdog 记录 Weston 和 Browser 存活，没有进程退出或 Wayland 断连。
- 运行 session 在约 900 秒按预定 duration 正常结束，未发送输入动作。
- readiness waiter 仍阻塞在已结束的 QMP socket 上，已手动清理。下一次 runner 将在 readiness 子进程运行期间同时观察 round PID，round 结束时立即终止 waiter 并写入显式 abort 结果。

## 判定

R75 不计入 Input 4/4，也不计入三次成功冷启动。它提供了同一候选在低内存和纯 TCG 下的首帧失败证据，和 R74 的局部输入通过结果分开保存。

