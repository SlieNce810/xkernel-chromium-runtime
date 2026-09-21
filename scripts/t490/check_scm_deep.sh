#!/usr/bin/env bash
# 核查 knet unix socket 的 sendmsg/recvmsg 与 SCM_RIGHTS fd 传递实现
exec > /mnt/e/02_competition/中电杯/tmp/scm_deep.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel && \
  echo "=== knet/src 结构 ==="; ls net/knet/src/ 2>/dev/null; echo "--- unix 目录 ---"; ls net/knet/src/unix/ 2>/dev/null || find net/knet -name "*.rs" | head -20; \
  echo "=== unix socket 的 fd 传递 / ancillary 处理 ==="; \
  grep -rn "ancillary\|Ancillary\|scm\|Scm\|rights\|Rights\|send_fds\|fd_table" net/knet/src/ --include=*.rs | head -30; \
  echo "=== posix/net/src/io.rs 里 SocketAncillary::Rights 上下文 ==="; \
  sed -n "100,140p" posix/net/src/io.rs; \
  echo "=== 接收侧 install fd（cmsg.rs 136-175）==="; \
  sed -n "130,180p" posix/net/src/cmsg.rs'
