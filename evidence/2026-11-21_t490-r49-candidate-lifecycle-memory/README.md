# R49：冻结快照阶段计时/生命周期/内存诊断

## 结果

R49 用 baseline freeze r3 的 frozen tracked diff 重建 R49 独立内核 worktree，并应用 stat22、resident-page/mapcount、process-tree rollup、dense PFN、direct-PTE 与 procfs phase-timing 六个补丁。构建通过，AArch64 kernel ELF SHA-256 `25311a6f…9b8d9f6`，实跑 kernel.bin SHA-256 `8e0a68a0…8d298d679`。平台为 T490、AArch64、2 GiB、4 vCPU、Cortex-A76、QEMU 10.2.1 pure TCG，平台检查15/15。

runner dry-run 验证了 1800 秒 initial-page deadline、1 Hz/900秒 memory sampler、lifecycle preload、guest clock sync、25秒 family watchdog、30秒 process scan、一次诊断 reload 和420秒保持；`qemu_started=0`。真实轮以 diagnostic-only 启动。QMP 在 guest 时间约1811秒前未通过任何 strict frame；53/53 张1280×800截图 strict FAIL，driver 记录 initial strict page gate timed out。Weston 和 Browser 在 timeout 前仍存活；liveness normalizer 1174/1174 PASS、没有修复项。诊断 gate RC78 表示按配置跳过正式稳定性门槛，不能覆盖 driver 的首屏失败。

900秒 guest 内存包 `BEGIN`/`END` 均存在，声明264块；本地严格提取器只收到248块，序号32–47整段缺失（提取失败：`memory chunk sequence mismatch: expected 32, got 48`）。`memory-export/chunk-sequence-audit.txt` 复核了 gap 和 console SHA。虽然原始串口显示完整的导出结束标记，本轮没有可接受的内存CSV，也不能计算RSS/PSS/USS峰值。guest console 还记录 `MP_LEDGER_LIMIT`：跨进程读取 Chromium 子进程 procfs 时 ledger reader 阻塞。

## 判定边界

此轮是 R49 candidate 上的高观测负载诊断，不是正式性能样本或稳定性 PASS。首屏 strict 超时，memory bundle有16个串口块缺失，Renderer/first-frame事件无法从未能完整解码的 lifecycle bundle 验证；collect_metrics 不运行在无效/不完整输入上。内核含阶段计时 patch，但没有可采纳的性能前后值。PPM 原件留在 T490，哈希索引为 [`evidence/_ppm-sha256-r49-candidate-lifecycle-memory.txt`](../_ppm-sha256-r49-candidate-lifecycle-memory.txt)；仓库保留初始与timeout PNG。

原始 console、完整命令、构建指纹、QMP transcript、liveness events、strict判据、driver结果及构建日志均保存在本目录。下一步应先降低诊断日志与串口争用并复测bundle传输，严格extractor保持拒收缺块样本；还需单独定位sampler/preload组合下的白屏，不据单轮结果归因。
