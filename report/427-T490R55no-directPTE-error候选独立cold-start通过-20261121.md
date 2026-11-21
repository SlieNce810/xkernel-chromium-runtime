# T490 R55 no-direct-PTE ERROR-only 独立 cold start 通过（2026-11-21）

R55 复用 R54/R53 的 no-direct-PTE ERROR-only candidate kernel.bin SHA-256 `c78ecd57…ad017a67`，2 GiB AArch64 pure TCG、官方 Chromium149镜像、official-index测试页。Dry-run检查通过且 `qemu_started=0`；真实诊断轮首屏 strict 在307.305秒host elapsed通过，真实Ctrl+R reload 1/1通过，随后保持420秒；事件normalizer243/243通过。PPM序列两张：shot-01为首帧前warmup，shot-02严格通过；stability子目录保留QMP确认的initial与reload strict画面，见 [R55 evidence](../evidence/2026-11-21_t490-r55-error-cold01/)。

R55 是R54正式稳定性PASS之后又一次独立的cold-start/reload页面通过，可作为最终候选冷启动复现材料。R53同一candidate/config在2400秒内曾首屏超时，失败轮仍应计入稳定性风险，不能用后续通过覆盖；R54+R55表明no-direct-PTE ERROR候选连续两次页面通过，但整体仍有间歇启动长尾。

R55为diagnostic-only、420秒保持，不计正式30分钟/10 reload门槛，也未启用memory sampler/lifecycle preload，因此不提供四项性能数据。原始PPM留在T490，SHA索引见 `evidence/_ppm-sha256-r55-error-cold01.txt`。
