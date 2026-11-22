# T490 2 GiB CSS 布局页 R1：页面 gate 通过，统一入口 SSH 收尾异常

## 结论

T490 远端 CSS 页面 gate 通过，获得 CSS 项 2/2 分。guest 运行 1,800 秒，实际 1,804.1 秒；27 张截图中前 4 张是空白启动画面，strict 失败被判为 warmup；第 5 张在 guest 481 秒首次通过 `official-layout` strict 5/5，之后到最终帧连续通过，共 23/27 张通过，`post_pass_fail=0`，最终 `score-page-gate.json` 为 `pass=true`、`round_rc=0`。2 GiB 浏览器功能累计为 16/20：HTML、Browser→Zygote→Renderer、双页签、JavaScript 和 CSS 已通过；Input 仍为 0/4。

统一入口的 Windows/WSL SSH 客户端在远端 round 和 CSS gate 完成后没有返回。为取回本轮结果，我结束了本地已无远端会话的 SSH 等待；因此该外层 `acceptance.json` 记录 `css` rc=255、overall rc=1。这个结果与 T490 保存的 `score-page-gate.json` 不同：远端截图判据和 `round_rc` 均通过，失败发生在收集命令退出状态的本地 SSH 通道。两份结果均保留，不能把外层通道错误写成 CSS 页面失败，也不能把本轮称为统一入口全程 PASS。

## 运行条件

| 项目 | 记录 |
|---|---|
| 主机 / guest | T490 / AArch64 QEMU 纯 TCG，guest 2 GiB |
| run tag | `codex-2026-11-18_135557-css` |
| 页面 / 进程模式 | `layout.html` / 默认 Browser → Zygote → Renderer |
| 窗口与绘制 | 1280×800、原生 Wayland、Chromium 149 `--js-flags=--jitless` |
| Chromium 镜像 | Chrome/149.0.7827.53，SHA-256 `d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641` |
| 统一入口命令 | `T490_TARGET=mo@10.249.11.192 bash scripts/final-acceptance.sh css` |
| 计划时长 | 1,800 秒；T490 manifest 记录实际 1,804.1 秒 |

## CSS 判据

- 截图 01–04（guest 240–420 秒）为启动空白帧，strict 失败；它们被 `round_assert` 计为 4 个 warmup 失败。
- 截图 05（guest 481 秒）首次通过 `official-layout` strict 5/5：`official_banner`、`verdict_fail_absent`、C1 flex row、C2 2×2 grid、C3 box model。
- 截图 06–27 持续通过；`score-page-gate.json` 记录 27 张、23 张通过、无首次通过后的回退，`pass=true`。
- `score-page-round.log` 记录 `ROUND_RC=0`，`ppm-summary.txt` 记录 `page_fail=0`、`post_pass_fail=0`、`pixel_policy_fail=0`，最终帧也通过。

截图复核显示 481 秒画面中的 C1、C2、C3 几何与页面标签一致。原始 PPM 留存在 T490，仓库保存 27 项哈希清单和两张可查看 PNG。

## 证据

- 完整 T490 运行证据：[CSS run](../evidence/2026-11-18_t490-codex-2026-11-18_135557-css/)
- 远端 CSS gate：[score-page-gate.json](../evidence/2026-11-18_t490-codex-2026-11-18_135557-css/score-page-gate.json)
- 可查看 warmup / 首次通过画面：[CSS 截图复核](../evidence/2026-11-18_t490-codex-2026-11-18_135557-css-review/)
- 外层入口退出记录（SSH rc255）：[acceptance evidence](../evidence/2026-11-18_t490-acceptance-135557/)
- 原始 PPM SHA-256：[清单](../evidence/_ppm-sha256-2026-11-18_t490-codex-2026-11-18_135557-css.txt)（27 项；原始 PPM 留存 T490）
