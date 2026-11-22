# R63：R62 兼容候选 Chromium 首屏失败

R63 使用 R62 构建的 no-direct-PTE、ERROR-only 候选内核，SHA-256 `12c0e795591d980503381dc9a487f3c24e5b227e569e9114c94983e3715b2ac0`。实际 QEMU `-kernel` 路径、运行配置中的预期 SHA 与该候选一致。它已在 [R62 compatibility bundle](../2026-11-21_t490-r62-compat-bundle/README.md) 通过 ABI 38/38、SCM_RIGHTS 6/6、memfd sealing 12/12 和 procfs 分配/COW/unmap probe。

Chromium/Weston 启动后，guest 约 110 秒时 console 报 `Fatal Wayland communication error: Connection reset by peer`；随后的 process watchdog 显示 `weston=yes chrome=no`。guest 240 秒截图严格集 1/7，画面未达到指定页面。确认 Chrome 持续不在后，为避免无效地继续等待 2400 秒首屏期限，结束了本次诊断 QEMU；没有发生导航重载或保持阶段。稳定性驱动 `Broken pipe` 是该次提前结束的结果，R63 不计为通过样本。

本轮没有内存/生命周期采样，不产生性能值；失败归档保留用于定位兼容性修复合并对 Wayland/Chromium 进程链的影响。原始 PPM 保留在 T490，SHA-256 见 [R63 PPM 清单](../_ppm-sha256-r63-r62-compat-cold01.txt)，本地有 PNG 预览和完整 console、事件、QMP transcript、平台命令和内核指纹。

精确内核路径/哈希的启动前干跑保存在 `preflight-dry-run.txt`，结果为 `qemu_started=0`。

详细分析见 [R63 报告](../../report/436-T490-R63-R62兼容候选Wayland首屏失败-20261121.md)。
