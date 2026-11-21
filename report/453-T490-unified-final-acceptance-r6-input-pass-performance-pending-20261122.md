# 统一验收状态 R6（2026-11-22）

## 当前结论

当前最终目标状态为 **INCOMPLETE**，剩余条款只在高阶性能批量统计与优化结论：

- 2 GiB 浏览器功能：**20/20 PASS**。
- 三次独立 2 GiB HTML 冷启动：**PASS**。
- 同一 a70e 候选稳定性：**PASS**；R70 正式轮 initial strict、10/10 reload、1804.991 秒保持、60 liveness、0 退出/异常。
- 同一候选兼容性摘要：**PASS**；ABI 38/38、SCM_RIGHTS 6/6、memfd 12/12、procfs memory probe 及 Browser→Zygote→Renderer 结构证据齐全。
- 2 GiB 真实输入：**R78 正式 PASS**，`input-gate.pass=1`，`pixel_policy_rc=0`，interaction-score gate=0。
- 四项性能指标：**0/0 有效 before/after 批次**；browser start、first frame、renderer create、RSS/PSS/USS peak 尚未形成各五次独立样本，也没有可靠优化收益结论。

## R78 输入证据

`evidence/2026-11-22_t490-r78-c80-tablet-input07/input-gate.json`：

- ready、before、input、round、QMP quit 和 pixel policy 均为 0；
- JS、keyboard echo、mouse counter、CSS navigation 和 real-input ledger 全部通过；
- 顶部 CSS 几何与底部 6/6 结论采用双帧判据；
- 真实动作账本为 30 个键盘动作、5 个 QMP 点击、5 个绝对 tablet 移动；
- 使用候选内核 SHA-256 `a70ecb4a…`、2 GiB、纯 TCG 和同一页面。

## 已提交的实现修复

- acceptance runner 在启动前校验预期 kernel SHA-256；
- tablet 输入模式强制 `virtio-tablet-pci`、QMP absolute pointer 和 settle interval；
- score gate 支持 staged source 同目录的 `ppm_assert.py`，并区分 absolute QMP 与 HMP relative 事件；
- CSS 导航分顶部几何帧和底部 6/6 结论帧；
- readiness 等待器感知 round 结束，避免 stale QMP 阻塞；
- pixel policy helper 具备 staged 路径回退并归档日志。

## 原始证据

- R70 正式稳定性：[evidence/2026-11-22_t490-r70-r64-compat-formal-lowshot/](../evidence/2026-11-22_t490-r70-r64-compat-formal-lowshot/)
- R70 进程链：[evidence/2026-11-22_t490-r70-process-structure-review/](../evidence/2026-11-22_t490-r70-process-structure-review/)
- R78 输入：[evidence/2026-11-22_t490-r78-c80-tablet-input07/](../evidence/2026-11-22_t490-r78-c80-tablet-input07/)
- 本审计：[evidence/2026-11-22_t490-final-report-r6/goal-audit.json](../evidence/2026-11-22_t490-final-report-r6/goal-audit.json)

性能条款仍需继续采集，不把当前 20/20 功能和稳定性/兼容性通过写成整项目标完成。

