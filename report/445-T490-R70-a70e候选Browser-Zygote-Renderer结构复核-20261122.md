# T490 R70：a70e 候选 Browser → Zygote → Renderer 结构复核

从 R70 正式稳定性运行的 console 派生 process-structure 事件，原 console 与 QEMU 会话没有修改或重跑。9 条 `MP_EVENT` 规范化 9/9、无修复；`multiprocess_eventlog.py --criterion process-structure --strict` PASS 4/4，进程父链为 Browser PID 70 → Zygote PID 174 → Renderer PID 308。完整 sidecar 和来源见 [R70 process-structure evidence](../evidence/2026-11-22_t490-r70-process-structure-review/README.md)；正式稳定性整体结果见 [R70 formal report](444-T490-R70-a70e正式稳定性通过-20261122.md)。

这关闭了 c80/a70e 候选上的默认多进程父链复核；键盘回显、鼠标点击、CSS 导航等 Input 评分仍是 0/4，不能用 Browser/Renderer 链 PASS 替代真实输入门禁。
