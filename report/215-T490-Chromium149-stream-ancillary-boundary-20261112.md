# T490 / Chromium 149：SOCK_STREAM ancillary 边界修复与多进程复核（2026-11-12）

## 结论

在默认 browser → zygote → renderer 路线上补齐了 x-kernel `SOCK_STREAM` 的 `sendmsg` 控制消息边界语义。每个 stream 写入现在带有已发布字节数和 ancillary 队列边界；接收端会在第一个带 ancillary 的写边界停止读取，并只在该边界完整消费后交付 `SCM_RIGHTS`/`SCM_CREDENTIALS`。这对应 Linux 的 `recvmsg` 行为，防止多个 Mojo 消息合并后把一批 fd 交给错误的消息。

修复已在 T490 通过纯 TCG 构建：

```text
x-kernel commit: b73e5814087c9d33c5f0a35b66cc56be689d3dee
kernel.bin SHA-256: da8cacc582d97578cd2725e7be2be256db33559626ddb232925064499582f282
stream patch SHA-256: 9ca2f9484db2a97c504221e7c27df16a08c16748968d76056fe2854d0286036e
```

## 实现

- `net/knet/src/unix/stream/channel.rs` 新增写边界记录，保存本次 `sendmsg` 已发布的字节数和控制消息。
- `net/knet/src/unix/stream.rs` 在发送端跨 ring-buffer 分片累计同一写入的长度；在接收端按边界计算本次最大读取长度，消费完整边界后再把 ancillary 放入 `recvmsg` 输出。
- `MSG_PEEK` 不推进 ring-buffer 和 ancillary 边界。
- 无 ancillary 的普通写入也保留边界，保证后续带 `SCM_RIGHTS` 的消息不会被前一条写入吞并。

补丁见 [report/215-xkernel-stream-ancillary-boundary.patch](<E:/02_competition/中电杯/report/215-xkernel-stream-ancillary-boundary.patch:1>)。

## Linux 对照

在 T490 宿主 Linux 上用同一个 `AF_UNIX/SOCK_STREAM` socketpair 连续发送两条 8 字节 `SCM_RIGHTS` 消息，接收缓冲区为 64 字节：

```text
recv1 = 8 bytes + first fd
recv2 = 8 bytes + second fd
```

如果第一条没有 ancillary、第二条带 ancillary，Linux 会把前一条普通数据与第二条带 ancillary 的数据一起交付，并把第二条 fd 附在这次 `recvmsg` 上。修复后的 x-kernel 队列按同一规则计算边界。

## Chromium 149 证据

本轮默认多进程 evidence：

```text
/home/mo/xk6/evidence/2026-11-12_t490-mp-stream-ancillary-boundary-20261112-r1/
```

观测到：

- renderer 侧 Ipcz 帧头保持有效，首字段是 `size=16`、`num_handles=1`、`num_bytes=184`；对应 `recvmsg` 同时收到一批 ancillary，随后 x-kernel 记录到 renderer 新 fd。
- 同一临时共享对象、同一页偏移在 browser 与 renderer 中得到相同物理页，排除了简单的 MAP_SHARED page-cache 不一致。
- Browser 读取指定 HTML 6832 字节：两个 `SANDBOX_PREAD_HTML` 事件完整出现。
- stream 边界修复后的这一轮仍未出现 `DocumentLoader`/`DidCommitNavigation`，严格像素判据为 `page_fail=1`、`strict_fail=6`，因此不能写成页面 PASS。

该结果说明修复解决了一个真实的 Linux IPC 语义缺口，但当前首帧断点还在更高层的 renderer bootstrap / 文档提交路径。`--renderer-process-limit=1` 和 legacy Mojo A/B 也没有单独恢复首帧。

## 验证状态

```text
make build MACHINE=aarch64-qemu-virt        PASS
remote git diff --check                      PASS
默认多进程 renderer 结构                       PASS（已有 4/4）
指定页面 DocumentLoader/DidCommit             FAIL
Wayland 有效页面帧                            FAIL
```

本补丁不是单进程替代，也没有改变正式启动形态；它应保留在后续 Chromium 多进程轮中，并配合真实页面提交事件继续定位。
