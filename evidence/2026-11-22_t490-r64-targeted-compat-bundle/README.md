# R64：目标 SCM_RIGHTS 补丁候选 focused bundle

R64 用 2 GiB AArch64 pure-TCG 对照内核 `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`。源码从兼容候选派生，重新以 c78 的 `net/knet/src/unix/stream.rs` 为起点，只应用 `scm-rights-first-byte.patch`；保留 no-direct-PTE resident walker、ERROR-only 配置及 inotify、memfd、madvise、页归属修复。

focused bundle 通过：ABI 38/38、SCM_RIGHTS short-read 6/6、memfd sealing 12/12、procfs memory probe 返回 0；共享/COW 阶段得到 RSS/PSS/USS/Shared 可解释数值。platform compliance 15/15。完整命令、环境、构建日志、内核指纹及 probe 原文在本目录。

该轮没有启动 Weston/Chromium；两个 640×480 黑帧不是有效页面截图。probe 脚本在 5 个 30 秒 hold tick 后结束，本轮不构成浏览器功能、稳定性或性能结果。R63 的 Wayland reset 因此仍未定位；R64 与 R62 的来源 diff SHA 相同，单靠补丁路径名称不能把它当作已成功的单变量浏览器对照。

原始 PPM 仅留在 T490，SHA-256 见 [R64 PPM 清单](../_ppm-sha256-r64-targeted-compat-bundle.txt)。详细分析见 [R64 报告](../../report/437-T490-R64最小SCMRights候选focused兼容通过Wayland待定位-20261122.md)。
