# R54：no-direct-PTE ERROR-only 候选正式稳定性复跑

R54 使用 no-direct-PTE、`LOG_LEVEL_ERROR` 冻结派生候选，在 2 GiB AArch64 pure TCG 下通过正式稳定性条件：initial strict page PASS、真实Ctrl+R 10/10 strict reload、通过后保持1805秒、60个QEMU liveness样本、无Browser/Zygote/Renderer退出和guest异常。event normalizer 762/762 PASS。首个strict页的host elapsed为276.694秒（该值来自host单调时钟，仅作运行诊断，不是guest性能指标）。

原始 runner 在临时 staged source 下错误使用默认pixel checker root，写入 `STABILITY_GATE_RC=1`；页面帧自身 strict像素判据通过。用显式 checker 对完全相同的R54原始事件/console/PPM哈希重跑gate，返回 `pass=true`，输出位于 `stability/stability-gate-final.json`。checker路径根因和 runner 修复见 `gate-recheck/checker-root-analysis.txt`。原始 `stability-result.env`/`stability-gate.log` 保留，未覆盖原始失败标记。

仓库已修复runner：将同目录 `ppm_assert.py` 通过 `--checker` 显式传给 `stability_gate.py`；新增staged-source路径回归。修订版runner在T490正式参数 dry-run显示 `qemu_started=0`；稳定性gate单测7/7、完整Python测试集78/78通过。

范围：R54关闭memory sampler、lifecycle preload和guest clock-sync，因此没有任何四项正式性能样本。R53相同no-direct-PTE ERROR配置曾发生首屏超时，R54表明candidate仍有间歇风险；正式稳定性PASS完成一次，三次独立冷启动和最终一键复现仍待补齐。
