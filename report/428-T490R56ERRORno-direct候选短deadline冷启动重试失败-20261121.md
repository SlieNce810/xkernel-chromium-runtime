# T490 R56 no-direct-PTE ERROR-only cold-start retry 未通过（2026-11-21）

R56 复用 R54/R55 的 no-direct-PTE、ERROR-only candidate kernel.bin SHA-256 `c78ecd57…ad017a67`，2 GiB AArch64 pure TCG、官方Chromium149 rootfs与official-index页面。使用diagnostic-only runner、1200秒readiness timeout、memory sampler/preload/clock-sync关闭；dry-run通过。

页面在1200秒内未strict通过，driver RC1、QEMU session RC0、normalizer430/430 PASS、diagnostic gate RC78；4张周期截图strict全失败，timeout时Weston/Chrome仍存活。此timeout小于正式default 2400秒，因此R56是cold-start诊断失败，不是正式稳定性gate。

同一no-direct ERROR candidate 的 R53（2400秒formal）未到首屏，R54在相同候选上完成正式10/10 reload与1805秒保持PASS，R55短诊断也strict/reload通过，R56再次未在1200秒内到首屏。R54/R55成功帧仍计入独立cold-start成功材料；R53/R56失败必须保留。该候选启动不稳定，需R57以2400秒deadline重复，并在最终三次cold-start数中同时呈现失败率与成功率。

R56关闭memory sampler，不产生四项性能值。完整console、命令、platform、PPM、normalizer和liveness证据见 [R56 evidence](../evidence/2026-11-21_t490-r56-error-cold02/)；raw PPM留在T490。
