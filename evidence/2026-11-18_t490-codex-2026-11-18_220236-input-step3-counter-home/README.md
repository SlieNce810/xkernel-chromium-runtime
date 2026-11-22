# R16 step3 ready timeout

R16 使用 2 GiB / AArch64 纯 TCG / step3 / `EVDEV_PROBE=0`。ready gate 在 2,000 秒内未通过，因此计数点击、CSS 导航和 Home 回顶都没有执行。

- `runner/ready.log` 为 `PAGE_READY_TIMEOUT`；readiness PPM 只留在 T490 的 `readiness-raw/`。
- `runner/qmp-timeout-quit.jsonl` 和 `runner/round.log` 记录 QMP timeout quit 成功，`QMP_TIMEOUT_QUIT_RC=0`。
- 26 张正式截图、187 张 readiness 原图和各自 SHA-256 均保存在 T490；仓库中只收可查看 PNG 和哈希清单。

详细结论见 [report 319](../../report/319-T490-2GiB输入尝试r16计数坐标加home校正前ready再次超时-20261118.md)。
