# R55：no-direct-PTE ERROR-only 独立 cold start

R55 复用 R54/R53 的 no-direct-PTE、`LOG_LEVEL_ERROR` candidate kernel.bin `c78ecd57…ad017a67`，guest2 GiB AArch64 pure TCG。Dry-run通过；首屏 strict 在307.305秒host elapsed通过，真实Ctrl+R reload 1/1通过，随后诊断保持420秒；liveness normalizer 243/243 PASS。PPM序列有2张图，首个周期帧为warmup失败，后续strict页面和重载帧通过。

该轮是一份额外独立cold-start证据，gate按diagnostic-only跳过(rc78)，不计正式30分钟稳定性。R53同一ERROR候选曾在2400秒内首屏超时，R54同一候选正式10 reload/1805秒通过，R55短诊断再通过，说明启动存在明显间歇长尾；三次独立cold-start已有成功帧，但必须保留R53失败，不覆盖失败记录。

R55关闭memory sampler、lifecycle preload与guest clock-sync，不产生启动、renderer、first-frame或峰值内存性能值。原始PPM在T490；哈希索引为 `evidence/_ppm-sha256-r55-error-cold01.txt`。
