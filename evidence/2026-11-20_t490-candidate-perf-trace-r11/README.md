# T490 Chromium 稳定性截图新鲜度与trace试采 R11（2026-11-20）

## 运行结论

R11使用2 GiB、AArch64纯TCG、Chromium 149.0.7827.53、Weston DRM/Pixman和默认 Browser→Zygote→Renderer。指定首页严格截图在启动后约590.218秒通过。driver随后保持650.0006秒，21个host/QMP存活点、330个guest watchdog点和427条稳定性事件归一化全部通过；QEMU正常结束。

该轮以 `diagnostic-only` 启动，`STABILITY_GATE_RC=78`，只有一次reload和650秒保持，不能计为正式稳定性验收。

## 导航截图新鲜度回归

QMP `Ctrl+R` 请求时间为host monotonic elapsed 620.220秒；事件账本在同一host时钟记录30秒等待屏障。首次reload截图在请求后30.8695秒采集，比最早截图门限晚0.8695秒；随后严格页面判据通过，并引用相同截图路径和SHA-256。初始页与reload截图均通过strict像素判据，静态页面前后SHA相同是预期行为。R11实机确认新门禁实际生效。

240秒周期截图仍是Chromium启动前的桌面背景，严格判据失败；它不覆盖后续页面通过结果。可查看该截图及两张strict页面截图：[启动前桌面](screenshots/shot-01-at0240s.png)、[初始页](screenshots/load-00-initial.png)、[reload页](screenshots/load-01-reload.png)。原始PPM留在T490，三张哈希见 [ppm-sha256.txt](ppm-sha256.txt)。

## Trace完整性

trace源文件声明20,875,836字节、SHA-256 `47f6f203e81e52c4b15aa04fdc2a475254d01af554dd32745d408e0bb254a949`，预期8,842块。串口日志到达序号8810，共8,811块，少31块且缺少END标记。抽取器因此拒绝生成JSON；该trace不能用于指标，也不能做event inventory。R12需要增加trace导出后的保持时间或降低捕获体积，再重采一轮。

四项性能指标本轮均为无效/0样本；没有进程树RSS/PSS/USS秒级数据，也没有before/after样本。

## 原始证据

命令、环境、完整console、QMP transcript、427条稳定性事件、截图判据和manifest均收在 [remote-archive-no-ppm.tgz](remote-archive-no-ppm.tgz)。归档SHA-256为 `87dbdf1806ea053fe5a908690a3408ac5a5e1997bd714b240c8ecd84d1f6af14`；未包含原始PPM。

\n