# R56：no-direct-PTE ERROR-only cold-start retry 02

R56 复用 R54/R55 的 no-direct-PTE、ERROR-only kernel.bin `c78ecd57…ad017a67`。平台仍为2 GiB AArch64 pure TCG，官方rootfs/Chromium149、同官方页面、memory sampler/preload/clock-sync关闭。Dry-run通过；实际运行将ready timeout缩短为1200秒，用于快速cold-start复测。

guest在1200秒内没有strict页；driver RC1，normalizer430/430 PASS，Weston/Chrome在timeout时仍活。4张周期截图均strict失败。由于readiness timeout比正式default2400秒短，本轮只作诊断，不是正式稳定性gate，也未进入reload或hold阶段。

R54在同一candidate/config下通过正式gate，R55冷启动/reload也通过；R53和R56分别记录了2400秒与1200秒内未到首屏的失败。无direct ERROR候选启动具有明显长尾/间歇性，R57继续用2400秒deadline复测。raw PPM保留在T490，SHA索引见 `evidence/_ppm-sha256-r56-error-cold02.txt`。
