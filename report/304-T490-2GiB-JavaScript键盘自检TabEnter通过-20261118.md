# T490 2 GiB JavaScript R1：QMP Tab/Enter 自检通过

## 结论

JavaScript 评分项在统一 2 GiB 平台参数下通过，获得本项 2/2 分。页面先通过 `official-interaction` strict ready 判据；随后执行真实 HMP 窗口激活点击、QMP Tab 和 Enter。输入后截图显示 T1–T6 六项自检全部通过，附加文件系统检查也通过。统一入口的单阶段输出为 `BROWSER_SCORE=2/20`；结合此前已通过的 HTML、Browser→Zygote→Renderer 进程结构和双页签，2 GiB 当前累计为 14/20。

这轮只证明键盘焦点与 Enter 能触发页面 JavaScript 自检。R3 的文本输入回显和鼠标点击导航仍未通过，不能把 JavaScript 2 分折算成真实键鼠输入 4 分。

## 运行条件

| 项目 | 记录 |
|---|---|
| 主机 / guest | T490 / AArch64 QEMU 纯 TCG，guest 内存 2 GiB |
| run tag | `codex-2026-11-18_133026-javascript` |
| 页面 / 进程模式 | `official-interaction` / 默认 Browser → Zygote → Renderer |
| 输入序列 | HMP relative mouse 在 `(640,400)` 激活窗口；QMP `send-key Tab` 后 `send-key Enter` |
| Chromium 镜像 | Chrome/149.0.7827.53，SHA-256 `d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641` |
| 统一入口 | `T490_TARGET=mo@10.249.11.192 bash scripts/final-acceptance.sh javascript` |
| 时间 | 13:30:26 开始，13:45:03 结束；页面在第 44 次 ready 采样通过后执行自检，随后通过 QMP quit 正常停止 |
| 沙箱 | `diagnostic-no-sandbox`；本轮只验 JavaScript 功能，不作为原生沙箱证明 |

## 判据与结果

| 判据 | 结果 |
|---|---|
| 页面 ready | PASS，`ready_rc=0`；strict `official-interaction` 页面判据通过 |
| 输入步骤 | PASS，`input_rc=0`；HMP 窗口激活点击、QMP Tab 和 Enter 均有对应 ledger 记录 |
| JavaScript 自检 | PASS，T1–T6 全通过；自检结论条变绿 |
| 附加文件系统检查 | PASS（页面标注为附加观察、不计分） |
| 截图与像素 | `ppm_assert_rc=0`，strict 集 4/4；像素差分 72,063 个变化像素，区域集中在交互表格，`input_changed_pixels=1` |
| QEMU 轮次 / 总 gate | `round_rc=0`、`pass=1`；统一入口 `javascript` 阶段退出码 0 |
| CDP 辅助观测 | `cdp_rc=1`，只作辅助信息，不参与像素和功能 gate |

后截图里的 `interaction_awaiting_input` 参考项显示失败，是因为该轮已触发自检、不再处于“待检测”状态；它不属于 strict 核心集。`interaction_selfcheck_pass` 参考项显示通过，并与截图上可见的 T1–T6 绿色结果一致。

## 证据

- 完整会话材料：[JavaScript 运行证据](../evidence/2026-11-18_t490-codex-2026-11-18_133026-javascript/)
- 统一入口汇总：[acceptance stage](../evidence/2026-11-18_t490-acceptance-133026/)
- 可查看前后截图与复核摘要：[JavaScript 截图复核](../evidence/2026-11-18_t490-codex-2026-11-18_133026-javascript-review/)
- 原始 PPM SHA-256：[清单](../evidence/_ppm-sha256-2026-11-18_t490-codex-2026-11-18_133026-javascript.txt)（57 项；原始 PPM 留存 T490）
