# T490 · 2 GiB 真实输入尝试 r1（页面就绪后 QMP 助手异常）

## 结果

r1 在 2 GiB AArch64 纯 TCG 会话中，于第 54 次 readiness 截图通过 `official-interaction` strict 页面判据；页面截图清楚显示交互控件处于“待检测”状态。随后 `qmp_input.py` 在准备发送绝对指针事件时抛出 `NameError: name 'os' is not defined`，因此没有完成键入 `hello x-kernel`、按钮自检或鼠标跳转。该轮 `ready_rc=0`、`input_rc=1`、`ppm_assert_rc=99`、`pixel_policy_rc=99`、`input_changed_pixels=0`、`round_rc=0`、`pass=0`；不能计为输入功能通过。

| 项目 | 实测 |
|---|---|
| 主机 | ThinkPad T490，10.249.11.192，Ubuntu 26.04.1 LTS，Intel Core i7-8665U |
| 命令 | `T490_TARGET=mo@10.249.11.192 bash scripts/final-acceptance.sh input` |
| T490 runner | `env -u PLAT_MEM_OVERRIDE MULTIPROCESS=1 EXTRA_FLAGS_VALUE=--js-flags=--jitless READY_TIMEOUT=2000 bash scripts/t490/run_input_final.sh codex-2026-11-18_120510-input 2400 60` |
| QEMU | 10.2.1，`-m 2g`，4 vCPU，cortex-a76，AArch64 纯 TCG，virtio GPU/键鼠，Weston/原生 Wayland |
| 页面就绪 | 第 54 次 `official-interaction` 检查通过；对应截图为 readiness `ready-054.ppm`，等待态完整可见 |
| 输入动作 | 尚未发送成功；异常发生在 `qmp_input.py` 读取 `QMP_STABLE_INPUT_IDS` 环境变量、构造首个绝对指针事件之前 |
| 结果码 | readiness 通过；input gate 失败；round 返回 0。CDP 是辅助状态，未连通不参与输入 gate |
| 会话时长 | 637.8 秒；发现异常后用 QMP `quit` 正常结束，不等待 2400 秒会话上限 |
| PPM | 59 张原始 PPM 保留在 T490；仓库保存其 SHA-256 清单和一张页面就绪查看图 |

## 最小复现与修复

故障源码在 [`qmp_input.py`](../scripts/t490/qmp_input.py#L236)：`input_events()` 调用 `os.environ.get("QMP_STABLE_INPUT_IDS", "0")`，但本轮实际运行文件 SHA-256 `83eeb46a008671ee5245430780acbad8c5f886fab0c8badc08b379ac09eef59a` 的 import 区没有 `import os`。T490 原始 traceback 在 [qmp-input-error.log](../evidence/2026-11-18_t490-codex-2026-11-18_120510-input/qmp-input-error.log)，严格通过的页面图在 [ready-054.png](../evidence/2026-11-18_t490-codex-2026-11-18_120510-input-review/ready-054.png)。

修复是在 import 区加入 `import os`，当前仓库和 T490 上该文件 SHA-256 均为 `c2dcadb9c5c53fd856a4da1d64bc46e97fed56dd2a3e00b8d3075b37aea9a3b6`。修复后的 `--help` 参数检查已通过；该修复的真实键鼠回归尚待下一轮，因此输入门仍保持未完成状态。本问题属于验收助手代码缺陷，不是 x-kernel syscall 兼容性结论。

## 证据

- [R1 完整输入失败证据](../evidence/2026-11-18_t490-codex-2026-11-18_120510-input/)：命令、环境、console、readiness 事件、`ready_rc=0`、QMP traceback、失败 gate、session-stop 记录和 bundle 哈希。
- [59 张原始 PPM SHA-256 清单](../evidence/_ppm-sha256-2026-11-18_t490-codex-2026-11-18_120510-input.txt)：PPM 原件均保留在 T490。
- [页面就绪查看图与判据](../evidence/2026-11-18_t490-codex-2026-11-18_120510-input-review/)。
- [统一入口 R1 阶段摘要](../evidence/2026-11-18_t490-acceptance-120510/acceptance.json)：Input 4 分项未通过。
