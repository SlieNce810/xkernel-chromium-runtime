# Chromium 149 链接前置检查（R109，2026-11-22）

R109 对 exact Chromium 149 的 `chrome` 目标执行 Ninja dry-run，确认 R108 的两个 AArch64 对象还不能直接组成可运行 Browser。输出目录为 T490 的 `out/tryframe-root4`，源码 revision 为 `9d2c8156a72129edca4785abb98866fad60ea338`。

## 结果

- `ninja -C out/tryframe-root4 -n chrome` 展开 31,209 个动作，最后一步才是 `LINK ./chrome`。
- `ninja -d explain` 显示最早缺失的是 Blink renderer 对象，另有一个 Mojo module 的输入时间更新导致重新生成。
- 当前缓存有 23,065 个 `.o` 和 1,193 个 `.a`，但还不是 `chrome` 的完整链接闭包。
- 本轮没有启动真实构建或链接，没有改动正式 Browser，没有 guest 启动，也没有性能数据。

这组信息解释了为什么 R108 先停在对象级验证：直接执行完整链接会触发大规模缺失依赖构建，不能被误记为已经得到可运行的 instrumented Chromium。

## 证据

- [remote-summary.txt](../evidence/2026-11-22_chromium149-link-dryrun-r109/remote-summary.txt)
- [cmd.txt](../evidence/2026-11-22_chromium149-link-dryrun-r109/cmd.txt)
- [summary.txt](../evidence/2026-11-22_chromium149-link-dryrun-r109/summary.txt)
- [manifest.txt](../evidence/2026-11-22_chromium149-link-dryrun-r109/manifest.txt)

正式性能状态继续为 `0/0`；下一步若要得到运行时 `renderer_ready`，需要补齐这 31,209 个动作，或采用一套已经完成链接且与 R108 对象 ABI 一致的 Chromium 149 instrumented 输出。
