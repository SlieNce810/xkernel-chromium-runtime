# 稳定性驱动：增加导航后的截图等待门禁（2026-11-20）

## 变更

R10诊断发现，driver在QMP发送 `Ctrl+R` 后立即开始严格截图轮询；静态测试页可能在新导航完成前仍显示旧的有效画面。稳定性driver现在在每次reload后至少等待30秒才进行第一次严格截图，等待期间继续按周期查询QEMU状态、读取guest进程看门狗。正式运行要求等待时间不小于30秒且短于reload窗口；默认配置为30秒。

事件账本记录导航请求host monotonic时刻、最早允许的截图时刻和 `navigation_settle_wait` 事件。正式验收gate独立校验等待至少30秒、截图晚于门限、严格结果引用对应截图和SHA，避免只有driver自报等待值。截图内容相同仍是静态页的预期结果。

## 验证

- `test_stability_driver.py`：6项通过，其中包含等待屏障与保持心跳两项新测例。
- 稳定性门禁测试6项（含过早截图和缺失等待事件拒绝）、事件归一化测试7项通过。
- `collect_metrics.py` 测试9项、性能比较测试6项、trace抽取测试14项通过。
- `bash -n scripts/t490/run_stability_round_mp.sh` 通过；本地正式参数dry-run和T490远端dry-run均通过，均显示 `reload_settle_seconds=30` 且 `qemu_started=0`。
- 修正版脚本已同步到T490，并在T490重新跑过稳定性driver单元测试。

此提交尚未包含使用新等待门禁的完整稳定性实机运行结果；后续运行需单独归档。R10自身仍是诊断轮，不计为正式稳定性通过。

\n