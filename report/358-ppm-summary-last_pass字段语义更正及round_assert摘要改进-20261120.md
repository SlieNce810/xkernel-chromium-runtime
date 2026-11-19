# R3 `ppm-summary` 的 `last_pass` 字段语义更正（2026-11-20）

## 核查结果

R3 完成后，人工预览发现 shot-65 仍有 Chromium “Page Unresponsive” 对话框，而 `ppm-summary` 的末尾写 `last_pass=1`。逐帧 JSON 和 SHA 复核证明像素 strict gate 并没有误判：`ppm-assert-shot-65-at2174s.json` 的 `strict_fail_count=6`，失败项包括官方 banner 和四色块；shot-65 与 nav-02 timeout PPM SHA-256 都是 `d43a463ea020c202461e0b93f095b199f308c40042f9bbeaafeb6ba1ddfa15d0`。把这三张 T490 原始 PPM 临时回传到本地后，用仓库当前 `ppm_assert.py --profile official-index --strict` 重算：初始首页 `RC=0 / strict_fail_count=0`；nav-02 timeout 和 shot-65 均为 `RC=1 / strict_fail_count=6`。

实际歧义在 `scripts/t490/round_assert.sh`：旧变量 `LAST_PASS` 在任何帧 strict 通过时置1，之后不会在失败帧复位。因此 `GATE last_frame=shot-65 last_pass=1` 表示“本轮曾出现 strict PASS”，并不描述最后一帧。R3 同时记录 `post_pass_fail=55` 与 `page_fail=1`，正式 gate 仍正确失败。原始 R3 evidence 和 `ppm-summary.txt` 保留原貌；这份报告补充其字段含义。

## 摘要输出改进

`round_assert.sh` 已新增 `any_strict_pass` 与 `last_frame_strict_pass` 两个明确字段，并保留旧 `last_pass` 作为 goal audit 的兼容别名。gate 判定条件继续要求至少有一帧 strict 通过、通过之后没有 strict 失败、最终帧 strict 通过；这次改动只澄清摘要字段，不改变页面像素谓词。

## 验证与后续

- 原始 PPM 的回归结果及相同 SHA 见本报告上方；没有将 PPM 留在仓库或改写原始 R3 evidence。
- 本地与 T490 均通过 `bash -n scripts/t490/round_assert.sh`；同步后的 SHA-256 为 `45710c1b478955bfde94e12a1be33393c60b303fe89641bbd37937431405b3ea`，T490 原脚本备份仍保存在 `~/xk6/tmp/round_assert.sh.pre-any-strict-label-2026-11-20`。
- 后续正式轮会核对新增摘要字段。当前三次候选正式稳定性仍按 FAIL 处理；R3 仅有1/10次重载通过。
