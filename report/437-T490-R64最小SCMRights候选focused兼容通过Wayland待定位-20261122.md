# T490 R64：targeted SCM_RIGHTS 候选 focused 兼容通过

R64 内核 SHA `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f` 在 T490 2 GiB pure TCG 上通过 focused bundle：ABI 38/38、SCM_RIGHTS 6/6、memfd sealing 12/12、procfs 内存 probe 返回 0，platform gate 15/15。共享/COW阶段的 `smaps_rollup` RSS/PSS/USS/Shared 为 512/384/256/256 KiB；unmap 后 RSS 回到基线。完整数据见 [R64 evidence](../evidence/2026-11-22_t490-r64-targeted-compat-bundle/README.md)。

这次不是图形或 Chromium 复测：autorun 仅运行 probe，截图为 640×480 黑帧，未达官方 1280×800 页判据。R64 的 tracked source diff SHA 与 R62 相同，因此虽然启动命令只应用现有 SCM_RIGHTS patch，但构建后的代码树没有形成独立源码对照，不能据此把 R63 的 Wayland reset 归因或排除到该 patch。

下一步应在真正的 before/after A/B 中保留 R62 compatibility fixes，明确记录 R63/64 相同代码 diff 的事实，并拆分可能引起 compositor/Wayland 问题的其余改动；图形首屏 strict 和至少一轮重载通过前，不把候选升级为最终内核或启动正式性能批次。
