# R50：R49 候选的观测探针关闭控制

R50 复用 R49 冻结快照候选 kernel.bin `8e0a68a0…8d298d679` 和官方 rootfs `bab5c9f5…f7a9fdb1`，关闭 1 Hz memory sampler、lifecycle preload 和 guest clock-sync，保留 30 秒 process scan 与25秒 family watchdog；其他 QEMU、guest RAM、页面和 strict 判据保持一致。`run_stability_round_mp.sh --dry-run` 显示 `qemu_started=0`、2 GiB/AArch64/pure TCG，随后真实诊断轮启动。

首屏在1800秒 readiness deadline内未 strict 通过，driver RC1；59次页面轮询strict通过0次，53张1280×800周期截图全部失败。初始240秒截图显示Weston桌面背景，421秒截图为白屏；deadline时Weston/Chrome仍存活，watchdog可用内存约311 MiB。事件normalizer 567/567通过，0修复。Gate RC78表示diagnostic-only跳过正式门槛，不能解读为PASS。

与R49相比，关闭了sampler、preload和guest clock-sync这一组观察开关后，候选首屏仍失败，因此这三项组合不能单独解释R49白屏；因三项同时变化，此对照不提供单项因果结论。R50没有内存采样/lifecycle性能记录，不产出任何正式性能样本。R49与R50均使用带stat22、procfs tree rollup、resident-page和timing补丁的候选内核，与R44通过的冻结kernel不同。

原始console、QMP/liveness events、53张strict判据、完整命令、环境、build manifest、两个可查看PNG和PPM SHA索引均已归档。原始PPM保留在T490。
