# 关于本轮（demo-record-gtk-1013）

- 目的：验证 `-display gtk` 路线（QEMU 窗口直接上 T490 物理屏的 GNOME/Wayland 会话）
  是否可行，作为 OBS 完整流程录屏的前置。**结论：可行**——QEMU 进程持有
  `/memfd:wayland-cursor`（GDK 已连 Wayland），窗口出现在物理屏。
- 参数口径：本轮沿用了测量轮的 `SINGLE_HOLD_VALUE=120`（错配），因此 autorun 在
  约 135 s 后按设计清理了 Chromium/Weston，之后 screendump 拍到的是**残留最后一帧**
  （shot-03~05 仍 7/7），约 361 s 起画面被清屏（shot-06 起严格集失败）。
  这不是渲染缺陷，是参数错配；**完整录屏与功能演示请用 HOLD=600 的轮次**
  （如 `2026-10-13_t490-demo-record-gtk-1013b`，DUR=900 / HOLD=600）。
- 本轮内核 2a1b101（构建 d58ba99b）、镜像 bb25e0b2、overlay 56dba17c；
  `SINGLE_GATE=1`、首帧导航 75 s；10/10 screendump + PNG 入库。
