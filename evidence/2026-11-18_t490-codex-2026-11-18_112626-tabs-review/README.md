# 双页签截图复核

来源：T490 上 Chromium 149.0.7827.53、AArch64 纯 TCG、guest 2 GiB 的默认多进程页签运行。三张可查看 PNG 由 T490 原始 PPM 转换；原始 PPM 保留在 T490，仓库只提交 SHA-256 清单。

| 顺序 | 截图 | 判据 | PPM SHA-256 |
|---|---|---|---|
| tab-a-before | [tab-a-before.png](tab-a-before.png) | official-index strict PASS | `abbff252ef5c5f6c348c5009eefbc5a3d0ba1358dbb8e4db142364fff1388897` |
| tab-b-after-ctrl-tab | [tab-b-after-ctrl-tab.png](tab-b-after-ctrl-tab.png) | official-layout strict PASS | `8f316b013cd48738b45aaf9e5176432774b1272ebfc38a2b8fb9574d64186ff4` |
| tab-a-after-return | [tab-a-after-return.png](tab-a-after-return.png) | official-index strict PASS | `abbff252ef5c5f6c348c5009eefbc5a3d0ba1358dbb8e4db142364fff1388897` |

本地仓库判据脚本重新检查三张原始 PPM，三项 strict failure 均为 0；判据脚本 SHA-256 见 `tabs-local-pixel-recheck.json`。Tab B 截图通过其可视 strict 集；页面下方的完整 6/6 结论不在 800 像素视口内，这张图不替代 CSS 专项滚动复验。

完整 gate、QMP 事件、会话清单和 15 张 PPM 哈希见相邻的完整运行证据与仓库根 `evidence/_ppm-sha256-2026-11-18_t490-codex-2026-11-18_112626-tabs.txt`。
