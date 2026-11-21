# R62：no-direct-PTE ERROR 候选 focused 兼容性复测

R62 候选由 `b73e581` 基础工作树合入 final compatibility worktree 的 ABI 修复，复制 R53 的 2 GiB ERROR-only 配置，并恢复 `mm/page_table/src/table64.rs` 到基础版本；`resident_page_frames` 保持 no-direct-PTE 查询路径。构建内核 SHA-256 为 `12c0e795591d980503381dc9a487f3c24e5b227e569e9114c94983e3715b2ac0`。它尚未替换仓库 `compatibility-final` 的 ac1032 摘要。

在 T490 2 GiB AArch64 pure TCG 上，platform gate 15/15；全量 ABI `compatprobe` 38/38、SCM_RIGHTS short-read 6/6、memfd sealing 12/12、procfs 内存 probe 9 个阶段均执行成功。共享/COW 数值可解释：`file_shared_touched` 为 RSS 512、PSS 384、USS 256、Shared 256 KiB；fork 后父子 PSS/USS/Shared 变化与映射共享相符；unmap 后 RSS 回落。

该 bundle 仅启动 focused ABI/内存探针，没有启动 Weston 或 Chromium。QEMU 内两张黑屏 PPM 为 640×480，非 1280×800，不能作为图形通过材料。探针规定的五个 30 秒 hold tick 已完成；不是稳定性验收，不产生 Chromium 四项性能数据。紧随其后的 R63 Chromium 页面尝试发生 Wayland reset，见 [R63 报告](../../report/436-T490-R63-R62兼容候选Wayland首屏失败-20261121.md)。

完整构建日志、命令、平台检查、probe 输出和 source provenance 在本目录。原始 PPM 留在 T490，SHA-256 见 [R62 PPM 清单](../_ppm-sha256-r62-compat-bundle.txt)。
