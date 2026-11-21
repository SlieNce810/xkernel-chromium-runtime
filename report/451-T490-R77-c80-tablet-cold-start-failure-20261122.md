# T490 R77 c80 tablet 首帧失败与早停验证（2026-11-22）

R77 使用了 R76 的输入实现和已补齐的 `verify_pixel_policy.py` staged helper，但在输入动作开始前未达到严格 interaction 首帧，按冷启动失败归档。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 平台：2 GiB、AArch64 QEMU 纯 TCG、Weston 原生 Wayland、Chromium 149 默认多进程
- 输入设备：virtio keyboard、virtio mouse、virtio tablet
- readiness：85 张截图，最新 2/4（`official_banner`、`interaction_checks_table` 失败）
- runner：session 结束时写入 `READY_ABORT=round-ended-before-strict-page`，没有再等待 stale QMP
- 输入动作：未开始，没有 input gate；pixel policy helper 的路径问题在本轮已通过 staged copy 预先修正

本轮与 R76 的关系：R76 已证明输入子门禁全通过，R77 只反映首帧冷启动的间歇性失败，不改变 R76 的输入链路结论。证据保存在 `evidence/2026-11-22_t490-r77-c80-tablet-input06/`。

