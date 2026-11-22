# T490 R97 快照压缩串口导出通过（2026-11-22）

R97 将快速取样得到的完整快照块写入 guest `/tmp`，不逐行输出到串口。取样结束后，guest 执行以下校验链：

1. 将 `xk-memory-snapshot-samples.log` 打成单成员 tar；
2. gzip 并计算原始 tar 和 gzip 的 SHA-256；
3. base64、折行、解码、逐字节比较和 `gzip -t` 往返校验；
4. 通过带 run ID、块序号、块长度、块数和 SHA-256 的 `XK_MEMORY_EXPORT_*` marker 发送 gzip base64 块。

host 端使用 [extract_xk_snapshot_export.py](../scripts/t490/extract_xk_snapshot_export.py) 再次校验 marker、块序、base64、gzip、tar 成员和 SHA-256，恢复出 `xk-memory-snapshot-samples.log`，再交给 [parse_xk_snapshot_samples.py](../scripts/t490/parse_xk_snapshot_samples.py) 解析。

## 结果

R97 的 export header 为：

```text
run_id=r97-xk-snapshot-export bytes=12800 chunks=10
sha256=8197aa8fa36108257f1ee8b1b7b6c6b54304e45509db6315010926a9d12c835f
gzip_bytes=1763
gzip_sha256=9360a5fed9368d74e9672e2902401bd32ec10ef7ab5e489b7782bb8b3e088042
```

host 恢复结果为 `integrity=PASS`。快照解析结果：

| 项目 | 结果 |
|---|---:|
| 恢复样本块 | 20 |
| 完整快照 | 19 |
| `tree_changed` | 1 |
| 读取耗时中位数 | 338.5 ms |
| 读取耗时 P95 | 873.1 ms |
| begin 间隔中位数 | 803 ms |
| begin 间隔 P95 | 1371.3 ms |
| resident walk 中位数 | 31.864464 ms |
| mapcount 中位数 | 6.674400 ms |
| rollup 中位数 | 0.379616 ms |

完整材料在 [R97 evidence](../evidence/2026-11-22_t490-r97-xk-snapshot-export/)，包括原始 console、导出 JSON、恢复的快照日志、解析 JSONL、artifact SHA-256 和 PPM SHA-256。原始 PPM 没有提交。

## 判定

R97 解决了 R95 的串口逐行 marker 丢失问题，并建立了可复用的完整性校验链。它仍是 20 次、单轮、进程树尚未完全建立的采集器诊断，不构成正式 before/after 五轮性能结论；正式性能状态继续为 0/0。
