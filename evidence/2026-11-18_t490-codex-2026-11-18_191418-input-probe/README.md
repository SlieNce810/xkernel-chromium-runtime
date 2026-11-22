# R10 探针开启的 ready timeout

R10 使用 2 GiB / AArch64 纯 TCG / Chromium 149 默认多进程，`EVDEV_PROBE=1`。ready gate 在 2,000 秒内未通过，输入 driver 未启动；QMP timeout quit 返回成功，实际 QEMU 会话 2,013 秒结束。

- `console.log` 保留了探针启动与打开 `/dev/input/event0`、`event1` 的输出；本轮没有键鼠动作，因此没有 `EVDEV ev`。
- `runner/` 保存 188 次 readiness 判据、QMP timeout quit 请求/回执与 `QMP_TIMEOUT_QUIT_RC=0`。
- `screenshots-review/` 中 PNG 是从原始 QEMU PPM 转出的查看副本；末帧是灰白空屏。
- 26 张正式 PPM 位于 `screenshots/`，188 张 readiness PPM 位于 `readiness-raw/`；均保存在 T490。仓库根 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_191418-input-probe.txt` 为 214 张图记录 SHA-256。

详细结果见 [report 313](../../report/313-T490-2GiB输入尝试r10探针开启ready超时及QMP早退-20261118.md)。
