# T490 x-kernel `SOCK_STREAM` poll 闭包全锁点修复（2026-11-13）

## 新发现

此前只把 `StreamTransport::send/recv` 的 `channel.lock()` 改成了 `try_lock()`，但 I/O poll 闭包内仍有以下阻塞锁：

- `endpoint.tx_order.lock()`；
- `peer_endpoint.tx_order.lock()`；
- `outgoing_ancillary.lock()`；
- `incoming_ancillary.lock()`。

QEMU 回溯已经直接命中：

```text
ktask::future::KWaker::park
ksync::Mutex::lock
ktask::future::poll::poll_io
StreamTransport::send
```

因此旧 kernel 仍会在 `sendmsg` poll 闭包中触发 `blocked_resched`。这解释了为什么之前的 `channel.try_lock()` 证据没有消除 panic：剩余的 `tx_order`/ancillary 锁仍会在同一闭包里 park。

## 修复

将所有 `send/recv` poll 闭包内的阻塞锁改为：

```rust
let Some(guard) = mutex.try_lock() else {
    return Err(KError::WouldBlock);
};
```

`shutdown()` 和 `Pollable::poll()` 的非 I/O 闭包锁保持原语义，不把非阻塞门禁扩大到其它路径。

补丁见 [report/230-xkernel-stream-poll-all-locks.patch](<E:/02_competition/中电杯/report/230-xkernel-stream-poll-all-locks.patch:1>)。

## 构建与运行证据

```text
kernel.bin SHA-256:
5feaabb5a7fd48558cb93833abc1dadd0b930db67dc4649e1353b991cc86bd6b
```

运行：

```text
scripts/t490/run_score_page_mp.sh html stream-locks-r2 220 30
```

证据：

```text
/home/mo/xk6/evidence/2026-11-13_t490-stream-locks-r2/
evidence/2026-11-13_t490-stream-locks-r2/console.log
```

对比结果：

- **blocked_resched / kernel panic：本轮未再出现**；
- renderer 仍产生真实 IPC 流量并收到 browser 消息；
- renderer 仍在 15 秒后输出 `Terminating current process after 15 seconds with no connection.`；
- `FileURLLoader::Start` 和完整 HTML 读取仍出现；
- `DocumentLoader`、`DidCommitNavigation`、有效 PPM 仍缺失。

## 结论

这是一个已被回溯直接证明的 x-kernel 修复，已经消除了内核级 poll-lock panic，但它不是首帧修复。当前断点从“内核 poll 闭锁导致 panic”继续收敛到 Chromium primordial Mojo host `Ping` 回执/接口绑定。
