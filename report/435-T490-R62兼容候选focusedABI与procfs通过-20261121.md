# T490 R62：兼容候选 focused ABI 与 procfs 通过

R62 从 `b73e581` 基础 worktree 构建 no-direct-PTE、ERROR-only 候选 SHA `12c0e795591d980503381dc9a487f3c24e5b227e569e9114c94983e3715b2ac0`。它保留 R53 的 ERROR-only 配置和 resident-page 查询路径，合入兼容 worktree 的 inotify、SCM_RIGHTS、memfd sealing、madvise-hole、页缓存共享/COW 修复。`table64.rs` 已恢复到基础版本，不包含 direct-PTE API。

平台门禁 15/15，通过完整兼容性 bundle：ABI 38/38、SCM_RIGHTS short-read 6/6、memfd sealing 12/12、procfs 内存 probe 返回 0。`file_shared_touched` 的 RSS/PSS/USS/Shared 为 512/384/256/256 KiB；fork/COW 两侧 share/PSS/USS 变化可观测；unmap 后 RSS 回落。原始逐阶段数据、内核构建输出和 command 在 [R62 evidence](../evidence/2026-11-21_t490-r62-compat-bundle/README.md)。

R62 没有启动 Weston/Chromium；640×480 黑屏截图不满足图形画面验收。R62 也未启用 Chromium lifecycle 或每秒内存 sampler，不提供四项性能样本。紧随其后的 R63 在该 SHA 上报告 Wayland connection reset、Chromium 退出和严格页面失败；因此 R62 只证明 focused compatibility 层恢复，不能作为最终候选整体通过。详见 [R63 报告](436-T490-R63-R62兼容候选Wayland首屏失败-20261121.md)。

旧 c78 候选 R61 曾在 inotify、madvise hole、SCM_RIGHTS、memfd sealing 多项失败；这次合并消除了这些 focused probe 失败。后续要隔离 R63 的 Wayland reset，保持兼容修复并修正图形启动，再跑 Browser→Zygote→Renderer gate、真实输入、正式稳定性和性能样本。
