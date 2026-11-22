# R70：a70e compatibility 候选正式稳定性 PASS

R70 在正式候选 a70e kernel SHA `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f` 上，使用 2 GiB AArch64 pure TCG、Chromium 149.0.7827.53、2400 秒首屏期限、10 次真实 Ctrl+R（间隔120秒）、页面通过后 1805 秒保持。guest platform gate 15/15；实际 QEMU `-kernel` 路径/哈希与预期一致。

正式 gate 通过：初始页面 strict PASS，重载 10/10 strict PASS，保持 1804.991 秒，60 个 QEMU host liveness 样本，0 个 guest process exits、0 个未分类 exits、0 个 guest exceptions。事件归一化 974/974 PASS、0 修复；driver、round、normalizer、gate 全部 rc=0。页面通过前后的 Browser/Weston/Renderer liveness 均正常。正式周期截图间隔为1200秒，另外由 stability driver 捕获 initial/reload 判据。

guest 240 秒周期帧仍是白色暖机图，guest 1440 秒周期图严格通过；这不影响 driver 基于初始页面严格通过后计时和逐次重载判据。R70 是本候选的正式 30 分钟稳定性 PASS，但没有启用内存/lifecycle采集，不产生启动、首帧、renderer create 或峰值内存性能值。

原始 PPM 留在 T490：`/home/mo/xk6/evidence/2026-11-22_t490-r70-r64-compat-formal-lowshot`；SHA-256 见 [R70 PPM 清单](../_ppm-sha256-r70-r64-formal-lowshot.txt)。PNG 预览：

![R70 初始页通过](stability/load-00-initial.png)

![R70 第十次重载后页面通过](stability/load-10-reload.png)

完整 gate JSON、60 点 liveness、QMP transcript、10 次导航事件、命令、环境、构建 manifest 与 runner hash 都在本目录。精确 stability runner 干跑在 `preflight-dry-run.txt`；QEMU 命令和平台门禁见 [R70 preflight](../2026-11-22_t490-r70-r64-formal-preflight/README.md)。

此前 c80 candidate 诊断启动 3 次通过（R65/R66/R68），同 hash R67 超时；R69 使用30秒周期截图正式尝试首屏超时，R70用1200秒间隔通过。两次正式配置只有截图间隔不同、各一轮，可能与观察负载有关但不足以断言因果，失败样本仍保留。
