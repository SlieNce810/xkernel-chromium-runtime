# 完整流程录屏（demo-full-flow.mp4）

- 录制源：OBS 32.1 屏幕采集（T490 物理屏 GNOME/Wayland），原始文件
  `2026-10-13 11-59-09.mp4`（19:24，858 MB，1280x720@30，h264+aac）。
- 本目录交付版：`demo-full-flow.mp4`——裁掉前导 235 s（旧轮尾巴与桌面空档）与结尾
  死屏，保留：新 QEMU 窗口出现 → guest 引导 → Weston → Chromium → index 页渲染
  → **页面连续存活约 10 分钟** → 结束时页面仍在。730 s / 1280x720@30 / h264 /
  22.4 MB（x264 CRF 25 veryfast，movflags +faststart）；sha256 见 evidence 清单。
- 与录制轮 `2026-10-13_t490-demo-record-gtk-1013c` 一一对应：该轮
  SINGLE_GATE=1、SINGLE_HOLD_REACHED elapsed=615、13/13 screendump、11 张严格集
  7/7；原始 858 MB 母带留存 T490 `~/2026-10-13 11-59-09.mp4`（不入库，>100 MB）。
- 启动命令字面见证在轮次 `cmd.txt`（`-display gtk` 为演示显示后端；归档判据轮保持
  无头命令行，两者口径已在 report/42 说明）。
