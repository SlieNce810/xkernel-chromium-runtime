# T490 Chromium 149 R177 隔离链接包清单（2026-11-24）

R177 生成的 AArch64 ELF 已通过仓库现有打包工具形成 guest 覆盖包。包本体保留在 T490，
因为它约 140 MB，不写入 Git 历史；仓库提交对应的清单和命令材料位于
[evidence/2026-11-24_t490-chromium149-r177-link](../evidence/2026-11-24_t490-chromium149-r177-link)。

```text
T490 package=/home/mo/xk6/tmp/r177-package/chromium149-r177-isolated.tar.gz
package_sha256=9f4144a62f7f9a9eb82d4f081a81b9ae33debdc76cfd9acc0ad930c2d0f79747
package_bytes=140615114
member=usr/lib/chromium/chromium
source_sha256=58433b67eba7ecf4f6effaf7673ed6fe87f5640194ecd184b2106deca8803161
```

打包工具在 T490 返回：

```text
CHROMIUM_BINARY_PACKAGE_PASS source_sha256=58433b67eba7ecf4f6effaf7673ed6fe87f5640194ecd184b2106deca8803161 archive_sha256=9f4144a62f7f9a9eb82d4f081a81b9ae33debdc76cfd9acc0ad930c2d0f79747 bytes=140615114
```

证据目录保存了 `cmd.txt`、`link.sh`、`link.log`、`args.gn`、`package.manifest.txt` 和
`sha256.txt`。包使用的是 R177 隔离链接 ELF；它尚未经过新的干净 GN 全量构建、guest
冷启动、六项功能复验、30 分钟/十次加载稳定性或四项性能统计。因此该包可以作为截止日
提交中的可复核源码链接诊断产物，不能作为完整验收通过包。
