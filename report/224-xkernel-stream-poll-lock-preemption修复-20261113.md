# x-kernel StreamTransport poll 闭塞 mutex 修复（2026-11-13）

## 发现

Chromium 149 的 headless DOM 探针触发了 x-kernel 内核 panic：

```text
assertion failed: curr.can_preempt(2)

ktask::future::KWaker::park
ksync::Mutex::lock
ktask::future::poll::poll_io
knet::unix::stream::StreamTransport::send
```

故障发生在 `send_poller_with_nonblocking()` 的 `poll_io` 闭包内。闭包已经处于
异步 I/O 重试上下文，却直接调用 `self.channel.lock()`；当另一个 task 持有 channel
mutex 时，mutex 会尝试 park 当前 task，而当前运行队列禁止该时机的阻塞调度。

## 修复

远端 x-kernel 的 `net/knet/src/unix/stream.rs` 已把 `send` 和 `recv` 的 poll 闭包
中的阻塞锁改为 `try_lock()`：

```rust
let Some(mut guard) = self.channel.try_lock() else {
    return Err(KError::WouldBlock);
};
```

这样由 `poll_io` 负责让出并重试，不在禁止 park 的上下文中等待 mutex。原有 stream
ancillary boundary、peek 和 seqpacket 修复保持不变。

当前远端差异保存在 [224-xkernel-stream-poll-lock.patch](224-xkernel-stream-poll-lock.patch)，
供下一轮构建和回归重放。

## 验证

修复后再次运行 Chromium 149 headless 探针：

```text
不再出现 blocked_resched panic
```

正确 Chromium 149 Wayland 多进程轮也不再出现该 panic，但 renderer child-host
连接仍未完成，browser 仍会回收 renderer，HTML 首帧仍未通过。证据目录：

```text
evidence/2026-11-13_t490-score-html-headless149-trylock-r2/
evidence/2026-11-13_t490-score-html-149-stream-trylock-r1/
```

因此这是真实的 x-kernel 并发兼容性修复，消除了一个会拖死 Chromium IPC 的内核
崩溃点，但还不是 renderer 文档提交的充分修复。下一步继续围绕 `ChildProcessHost`
的 Mojo invitation 回执定位。
