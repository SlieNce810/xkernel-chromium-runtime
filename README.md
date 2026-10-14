# 基于 x-kernel 的 Chromium 运行环境构建与优化

中国电子杯 · 赛题六初赛。正式交付仅面向 T490 原生 Linux，采用 AArch64 QEMU 纯 TCG、Weston 和 Chromium 142 单进程路线。

正式材料入口是 [初赛提交说明](submission/README.md)、[精简技术方案](submission/技术方案.md) 和 [唯一证据集说明](submission/证据说明.md)。最终 ZIP 位于 `report/submission/xkernel-initial-final.zip`，同目录提供包 SHA-256 和文件清单；请从该 ZIP 解压复现。

提交物包含一份 T490 证据集、一份 730 秒完整录像、内核源码与配置、用户态 overlay，以及依赖闭合的 T490 运行脚本。基础镜像从固定 Release 获取并核对 SHA-256。包的精确白名单为 `submission/selection.json`。

主流程保持 615 秒，官方 index 严格判据通过；JS/CSS 验收、八条兼容性缺口及五次性能观测见精简方案。硬件输入链、renderer 多进程和性能改善档位均不超额宣称。上游 [PR !831](https://gitee.com/openkylin/x-kernel/pulls/831) 已合并，见技术方案。

`report/`、未选入的 `evidence/` 与历史脚本为研究归档。Windows/WSL2 仅用于开发测试，相关脚本、证据和验证说明不进入初赛提交物。该约束记录在 `AGENTS.md` 和项目记忆。报名表按用户要求跳过。
