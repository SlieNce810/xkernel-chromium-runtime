# R53：no-direct-PTE、ERROR-only log 的正式稳定性尝试

R53 在 R51 no-direct-PTE 冻结派生内核的补丁栈上，只改 `.config` 日志级别为 `LOG_LEVEL_ERROR=y`、关闭 `LOG_LEVEL_WARN`。内核 build 通过，kernel.bin SHA-256 `c78ecd57…ad017a67`；QEMU使用官方 rootfs、2 GiB AArch64 pure TCG、4 vCPU、Cortex-A76。

这是正式 runner 配置：dry-run `qemu_started=0`；10次Ctrl+R/120秒、1805秒保持、default 2400秒 readiness deadline、process scan30秒、family watchdog15秒、memory sampler/preload/guest clock-sync关闭。实跑首屏在2400秒前没有strict通过，driver RC1，gate RC1；因此没有执行reload或保持段。normalizer871/871 PASS；timeout时Weston/Chrome仍存活，guest memfree约307 MiB。周期PPM只有240秒和1440秒两张加timeout截屏，strict均失败。ERROR-only日志把console降到约168 KB，但没有让页面出现。

该结果说明 R51 no-direct-PTE页面成功尚未重复；R53的ERROR配置正式轮仍失败，可能是观测配置、时序方差或未定位候选问题，不能据此归因到log level。它不是稳定性PASS，不提供性能值。后续需在同一 no-direct binary/source 下复跑，并继续隔离启动/显示链。

本目录包括build、正式命令、环境、platform断言、QMP/liveness、PPM判据和PNG。raw PPM 留在T490，SHA索引见 [`evidence/_ppm-sha256-r53-no-direct-error-formal.txt`](../_ppm-sha256-r53-no-direct-error-formal.txt)。
