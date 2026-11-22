# Lifecycle JSONL 的显式 sequence 字段修复（2026-11-23）

## 发现

`scripts/collect_metrics.py` 的严格读取器要求每条 lifecycle 事件含有 `seq`，并按
它检查重复/乱序。此前 `lifecycle_event_preload.c` 只把本地计数器放进
`event_id`，事件 JSONL 没有独立 `seq` 字段。v7 因此可以人工解析，却不能直接
进入严格采集器。

## 修复

补丁 [0029](patches/0029-lifecycle-event-seq-field.patch) 在固定 schema 下新增：

```json
"seq": 1
```

由于 preload 在 fork 后每个进程拥有自己的静态地址空间，原子递增编号不能作为
跨 Browser/Zygote/Renderer 的全局序列。因此 `seq` 使用同一
`LINUX_CLOCK_MONOTONIC` 域的 `t_ns`，而 `event_id` 继续保留原有的本地编号以保证
身份唯一。这样采集器可以直接验证 run ID、clock ID、seq 单调性和 event ID 唯一性。

v7 现有的 `lifecycle-events.jsonl` 是修复前格式，只作为历史诊断材料保留；下一轮
使用同一 Chromium 149 preload 运行后，应先用 `collect_metrics.py` 的严格读取器
验证事件格式，再决定是否继续进入内存样本闭环。
