# T490 冻结根 R37 cold-start 页面通过但 family 快照 stale（2026-11-21）

## 冻结条件

R37 使用 baseline freeze r3 的 `/home/mo/x-kernel` 与 pkg-installed rootfs：kernel SHA-256 `51c4028594e4aff9fc5b9964c4294a2904621c93e84093ac711858c454aed284`，rootfs SHA-256 `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`。QEMU 实跑 `-m 2g -smp 4 -cpu cortex-a76`，pure TCG，virtio GPU/keyboard/mouse。Browser 实际 argv 保留 `--js-flags=--jitless` 和 `--ipc-connection-timeout=600`。

memory sampler 与 lifecycle preload关闭；process-tree scan30秒，family watchdog25秒，页面 ready deadline恢复默认2400秒。

## 结果

指定首页 `official-index --strict` 通过，QMP ready elapsed `466376.158592 ms`；1/1真实Ctrl+R重载通过，页面后420.001秒保持完成，Weston与Chrome进程存活。该轮确认冻结根上的页面链路可启动。

稳定性事件 normalizer 因 family snapshot freshness失败：5行快照 age 为38.675、39.027、39.028、42.030、43.023秒，gate限值35秒；因此R37不算完整 stability PASS。guest clock-sync未运行，因为本轮关闭了memory sampler，ready elapsed为runner host计时，只用于cold-start页面判定，不用于guest性能测量。

## 证据

R37的console、实际QEMU命令、冻结kernel/rootfs哈希、strict截图、QMP和normalizer错误见 [R37 evidence](../evidence/2026-11-21_t490-r37-frozen-cold01/)；原始PPM留在T490，仓库有 [哈希索引](../evidence/_ppm-sha256-r37-frozen-cold01.txt)。R38将 family watchdog interval 调为15秒、process scan保持30秒，以满足 freshness gate 并观察冷启动是否稳定。
