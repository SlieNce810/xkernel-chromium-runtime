# R8 输入页面超时证据

本目录保存 T490 运行 `codex-2026-11-18_172923-input` 的证据副本。会话于 2026-11-18 17:29:50+08:00 开始，平台检查 15/15 通过；页面 ready 在 2,000 秒后超时，28 张正式 screendump 的 strict 判据均未通过。

- `console.log` 是带时间戳的完整串口与 QEMU 日志；`manifest.txt`、`cmd.txt`、`env.txt`、`platform-compliance.txt` 固定了运行条件。
- `runner/` 保存 ready gate 的 JSON 判据、QMP 回执和日志。187 张 readiness PPM 原图留在 T490 的本轮 `readiness-raw/` 目录，以符合仓库原始图像存放约定。
- `screenshots-review/` 是第 1、28 张原始 QEMU PPM 的 PNG 查看副本；最后一帧为灰白空帧。
- 28 张正式 screendump PPM 与 187 张 readiness PPM 均留在 T490，分别位于本轮 `screenshots/` 和 `readiness-raw/`；仓库根的 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_172923-input.txt` 为 215 张图记录 SHA-256。
- `/root/mp-evdev.log` 未被停机后的 guest 日志回收流程恢复；串口仅证明 sniffer 启动，本轮没有输入 driver 动作，也没有可用 evdev 事件结果。
- `futex-trace-summary.json` 是对串口中前 4,096 条有界 Chromium futex 调用记录的事后配对统计；它将 wait 的普通 `WouldBlock`/`TimedOut` 与缺少操作码的通用 `OperationNotSupported` 分开记录。
- `futex-analysis.txt` 固定生成该汇总的命令与限制；R8 evidence 的 `sha256.txt` 会覆盖汇总 JSON 和本目录的副本材料。

详细判定见 [report 311](../../report/311-T490-2GiB输入尝试r8交互页再次ready超时-20261118.md)。外层统一验收日志和 SSH 收尾说明见 [acceptance evidence](../2026-11-18_t490-acceptance-172923/)。
