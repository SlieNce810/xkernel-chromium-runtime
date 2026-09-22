# 24 · Renderer 阶段 B：strace 结果

## 实测

证据轮：`evidence/2026-09-22_t490-strace-renderer2/`。

- Weston 与 `wayland-0` 正常建立。
- Chromium browser PID `40` 启动。
- `strace -ff -tt -s 256 -o /root/browser.strace -p 40` 已执行 attach。
- `FileURLLoader::Start` 出现。
- `renderer_count=0`。
- 阶段脚本收尾时没有得到有效 `browser.strace.*` 内容，串口 trace 尾部为空；因此本轮不能对 `rc=191` 作 syscall 或信号归因。

## 判定

strace attach 在当前 x-kernel guest 上没有形成可用证据，不能把空 trace 解释为“无 syscall”或“无信号”。当前可靠事实仍是：导航开始后没有 renderer，且 GPU separate 路径可复现退出码 `48896 = 191 << 8`。

下一轮应先把 attach 失败原因显式打印到串口（`/root/strace-attach.log` 的 rc、错误文本），必要时改为从 Chromium 启动前使用 `strace -f` 全量跟踪，避免 ptrace attach 权限或时序问题。
