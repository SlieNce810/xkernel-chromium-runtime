#!/usr/bin/env bash
# 核查 x-kernel 的 unix socket SCM_RIGHTS / fd 传递支持（seatd 依赖）
exec > /mnt/e/02_competition/中电杯/tmp/scm_check.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel && \
  echo "=== SCM_* 出现位置 ==="; \
  grep -rn "SCM_RIGHTS\|SCM_CREDENTIALS\|scm_rights" --include=*.rs . | head -20; \
  echo "=== sendmsg/recvmsg 支持 ==="; \
  grep -rn "fn sendmsg\|fn recvmsg\|SendMsg\|SO_PASSCRED" --include=*.rs . | head -20; \
  echo "=== unix socket 实现文件 ==="; \
  find . -path ./target -prune -o -name "*.rs" -print | xargs grep -ln "UnixStream\|unix_dgram\|sockaddr_un" 2>/dev/null | head -10; \
  echo "=== cmsg / control message 解析 ==="; \
  grep -rn "cmsg\|CmsgHeader\|control_message" --include=*.rs . | head -10; \
  echo "=== 构建日志（会话6期）dmesg 等价：boot 日志里的 socket 相关 ==="'
