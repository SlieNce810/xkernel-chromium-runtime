# T490 R54 no-direct-PTE ERROR-only 候选正式稳定性通过（2026-11-21）

## 正式验收结果

R54 使用 no-direct-PTE、`LOG_LEVEL_ERROR` 冻结派生候选；kernel.bin SHA-256 `c78ecd57…ad017a67`，guest2 GiB AArch64 pure TCG。Driver记录initial strict page PASS，首帧host elapsed276.694秒；10次真实QMP Ctrl+R reload全部 strict PASS，并在首个严格通过帧后保持1805秒。Event normalizer 762/762通过；正式 gate recheck记录 measured duration 1804.991685933秒、QEMU liveness60点、0 Browser/Zygote/Renderer exits、0未分类退出、0 guest exceptions。该轮完成一次正式30分钟/10 reload稳定性PASS。

## 初次gate错误与修复

原始R54 `STABILITY_GATE_RC=1` 来自 pixel checker路径计算错误，不是页面/事件失败。stability runner的脚本从临时staged source目录运行，`stability_gate.py` 默认 `Path(__file__).resolve().parents[2]` 推出 `/home/mo/xk6/tmp` 并寻找不存在的 `/home/mo/xk6/tmp/scripts/t490/ppm_assert.py`；原代码将checker子进程非零误报为通用截图strict重算失败。

初始截图用仓库同一 `official-index` strict checker 重新判定为7/7通过。针对完全相同的R54 normalized events、console与PPM SHA，稳定性gate显式使用同staging目录里的 `ppm_assert.py` 后返回 `pass=true`。重新核验结果和原始gate error均在 [R54 evidence](../evidence/2026-11-21_t490-r54-no-direct-error-formal-repeat/) 中，原始 `STABILITY_GATE_RC=1` 文件保留，没有覆盖。

仓库修复了源路径问题：`stability_gate.py` 增加 `--checker` 参数，并在checker文件缺失时报告具体路径；`run_stability_round_mp.sh` 显式传入 `$HERE/ppm_assert.py`，所以从临时staged source启动也会使用配套像素判据。新单测覆盖staged runner checker路径；稳定性gate专项7/7、完整Python测试集78/78通过，相关 shell/Python语法检查通过。修订后正式参数 dry-run显示 `qemu_started=0`。

## 限制与后续

R54关闭memory sampler、lifecycle preload、guest clock-sync，没有峰值内存、Browser启动、Renderer创建或first-frame性能数据。R53同一no-direct-PTE ERROR候选曾首屏超时，R54复跑通过，说明该候选冷启动仍有间歇性；还需补齐3次独立cold start和一次基于同一最终候选的一键复现。R54本身满足“一次30分钟/10次reload稳定性”要求，但不是四项性能验收。
