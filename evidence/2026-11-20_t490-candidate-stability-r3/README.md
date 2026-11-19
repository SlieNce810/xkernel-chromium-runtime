# Chromium 正式稳定性 R3

- 主机：T490 `10.249.11.192`；guest AArch64、2 GiB、纯 TCG；Chromium 149.0.7827.53。
- Kernel SHA-256：`ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`。
- 结果：首屏 strict PASS；nav-01 重载 PASS；nav-02 在16次采样后 timeout；完成1,805秒保持但正式 gate FAIL（1/10重载）。
- 65/65周期截图和928条归一化事件均归档；最后 watchdog 仍显示 Weston/Chrome 存活，OOM/进程退出为0。
- [报告 356](../../report/356-T490-ac1032正式稳定性r3完整保持但第二次重载超时-20261120.md) 说明判据、页面对话框和结果边界。
- 非 PPM 原始材料在 `remote-archive-no-ppm.tgz` 和展开的 `remote/` 树；68项原始 PPM 留在 T490，SHA 清单见 [ppm-sha256.txt](ppm-sha256.txt)。
- [首页](screenshots/load-00-initial.png)、[nav-01](screenshots/load-01-reload.png)、[nav-02 timeout](screenshots/load-02-reload-timeout.png)、[首个周期严格通过帧](screenshots/shot-05-at0360s.png)、[最终周期帧](screenshots/shot-65-at2174s.png) 为可查看 PNG 预览；本地不保留 PPM。
