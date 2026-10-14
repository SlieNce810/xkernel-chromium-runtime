# T490 初赛运行脚本

正式交付的脚本白名单见 `submission/selection.json`，复现命令见 `submission/README.md`（提交 ZIP 中为根 README.md）。历史诊断脚本不在交付包。

- `reproduce_submission.sh`：准备源码/镜像、构建、平台检查、干跑、900 秒主功能轮。
- `t490_round.sh`、`run_session_t490.sh`：独立工作盘、启动、串口与 QEMU 截图。
- `platform.env`、`t490_platform_check.sh`：AArch64 / TCG / 2G / 4 核及设备合规。
- `guest-autostart.sh`、`autorun_single_initial.sh`、`t490_inject_pages.sh`：guest 运行与三页注入。
- `pull_guest_logs.sh`、`round_assert.sh`、`ppm_assert.py`：原始日志回收及像素断言。
- `run_interaction_round.sh`、`qmp_input.py`、`cdp_input.py`：浏览器交互专项；不替代硬件输入全链。
- `measure-single-initial.sh` 及 scripts/ 下的观测/汇总工具：五次同栈性能观测。
- `autorun_submission_gaps.sh`、六个 probe 源码、`run_linux_gap_baselines.py`：八条缺口分项附件。

脚本支持 `XK6_ROOT`（提交解压根目录）和 `KERNEL_REPO`（内核目录），默认入口自动设置；不得覆盖已完成的证据目录。
