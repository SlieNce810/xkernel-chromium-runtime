# cold03 复核补充

本轮原始页面 gate 为 PASS（24/27 张 official-index 严格通过，最终帧通过）。原始外层 process gate 记录 rc=1：Browser 的第一条 MP_EVENT 在 console 中被截断到 timestamp、role、PID、PPID；同一 observer 随后输出的 MP_PROCESS_OBSERVED 行保留了相同的 Browser PID/PPID。

归一化器只在 role/PID/PPID 三者严格匹配时补齐 observer 固定字段，并在输出记录中标记 console_reconstructed=true。原始 console、原始 MP_EVENT 提取和第一次 gate 结果均未改写。归一化后的同轮事件经统一入口 score-process stage 和命令行禁止项校验后通过，结果 4/4：Browser 66 (PPID 5) → Zygote 161 (PPID 66) → Renderer 282 (PPID 161)。其他进程候选配对作为 alternate_parent_link_mismatches 保留，未覆盖这条直接父链。

这轮只证明 2 GiB 下的指定首页与默认多进程父链；它没有完成六项功能复验、30 分钟/10 次重载稳定性或四项性能测量。原始 27 个 PPM 保留在 T490。
