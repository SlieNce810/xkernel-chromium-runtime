# T490 Chromium 149 二进制打包工具验证（2026-11-23）

## 目的

为源码构建完成后的真实 guest 运行准备固定注入路径，新增
`scripts/t490/package_chromium_binary.sh`。工具只打包一个成员：

```text
usr/lib/chromium/chromium
```

它拒绝覆盖已有输出，检查输入是可执行 AArch64 ELF，并生成包含输入二进制 SHA-256、
tar SHA-256、大小和成员清单的 manifest。这样 `PKG_TARBALL` 和
`CHROMIUM_BIN_VALUE=/usr/lib/chromium/chromium` 可以在稳定性/性能轮中明确记录。

## T490 实测

使用已有预编译 Chromium 149 二进制做工具链验证。该轮不是源码构建结果，也不计入
正式性能或稳定性数据。

```text
source SHA-256  d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641
tar bytes       106904773
tar SHA-256     f7896bef18ae671cc16d7eeec946761af50426523738ba4a00bc194221e85e08
member          usr/lib/chromium/chromium
```

原始 manifest、命令和 SHA 清单保存在 [package tool evidence](../evidence/2026-11-23_t490-chromium149-package-tool-test/)。tar 原件没有提交仓库，仍由 T490 侧保留。

## 复核

- `--help`：通过；
- 不存在输入文件：返回 rc 66；
- T490 真实 AArch64 Chromium 149 输入：通过；
- tar 成员精确匹配 guest 路径；
- 二进制和 tar SHA-256 均写入 manifest；
- 当前 `autorun_mp_score_observe6.sh` 已改为使用 `CHROMIUM_BIN` 占位符，实际路径
  和 SHA 会写入 guest log；
- `run_stability_round_mp.sh` 的稳定性配置会记录 `chromium_bin` 与 `pkg_tarball`。

待源码 Chromium 149 构建完成后，使用同一工具对
`out/tryframe-root4/chrome` 重复打包，随后才进入新二进制的冷启动、生命周期、内存
和正式 before/after 验收。
