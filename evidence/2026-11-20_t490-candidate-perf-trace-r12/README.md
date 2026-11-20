# T490 Chromium Trace与PSS采样整合诊断 R12（2026-11-20）

## 会话和页面结果

R12运行于T490 `10.249.11.192`，2 GiB、AArch64纯TCG、Chromium 149.0.7827.53、Weston DRM/Pixman和默认多进程。首页strict通过于host elapsed 620.565秒；QMP `Ctrl+R` reload在请求后30.701秒取到strict截图，门限为30秒。诊断保持800.0006秒，reload 1/1，514/514稳定性事件归一化，26个host/QMP liveness与388个guest watchdog记录通过。由于标注为diagnostic-only，`STABILITY_GATE_RC=78`，不计入正式30分钟验收。

240秒周期帧是启动前的桌面背景；初始页与reload页的strict截图内容和SHA相同符合静态页预期。PNG预览见 [启动前桌面](screenshots/shot-01-at0240s.png)、[首页](screenshots/load-00-initial.png) 与 [reload](screenshots/load-01-reload.png)。原始PPM保留在T490，SHA-256见 [清单](ppm-sha256.txt)。

## Trace：序号齐全，base64内容无法解码

BEGIN/END均存在，3,159个块序号连续；gzip声明606,401字节，原始trace声明6,027,818字节。串口中实际base64字符808,431个，长度不是4的倍数，比606,401字节所需的808,536字符少105个；序号3124的块长度仅151，末块88。抽取器以 `Incorrect padding` 拒绝该trace，没有JSON和有效trace事件文件。四项性能指标没有从R12产生有效样本。

## 内存采样：guest拿到部分数据，但采样时限失败

新的guest采样器产生75个sample id、355行、9个进程身份和非零RSS/PSS/USS数据；包内状态为FAIL，错误日志有46条：43次采样overrun（中位10.644秒，最大204.888秒）以及2次process tree unavailable。记录时间从guest约41.343秒到945.244秒，实际间隔远超1.5秒限制，因此不计算峰值或资格线。仅作诊断的部分最大值为RSS310,332 kB、PSS278,679 kB、USS261,140 kB，均不得当作合格测量值。

这轮暴露出当前逐PID读取 `smaps_rollup` 会重复遍历所有进程的驻留页映射：内核 `task_smaps_rollup_usage()` 对每个目标任务都扫描完整process list并重新构造PFN mapcount，C采样器又逐个读取9个PID。下一步将评估一次全树快照接口或共享快照，降低重复遍历成本后再测1Hz门限。

## 时钟同步

guest输出77条 `MP_METRICS_CLOCK_SYNC`，因host解析器未匹配部分带ANSI前缀的行，仅配对14条；这些配对跨890.761秒拟合的斜率为0.999996954、最大残差43.7 ms。映射本身较稳定，但R13应修正ANSI匹配，保留更密的原始host/guest时钟配对。

## 原始证据

完整串口、稳定性事件、trace和memory base64串流、命令、环境、PPM判据与哈希清单见 [remote-archive-no-ppm.tgz](remote-archive-no-ppm.tgz)，SHA-256 `c33c4e8f54f32b30fbee614977391df80cd2ac66f6dae1f16feaf4742f8d5c7e`。R12 memory tar已保留在 [memory-export/](memory-export/)，`extraction.json`明确标记valid=false并记录样本错误。

\n