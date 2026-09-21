#!/usr/bin/env bash
# 精确核查 AF_UNIX 支持 + 顺带看构建进度
exec > /mnt/e/02_competition/中电杯/tmp/scm_check2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel && \
  echo "=== AF_UNIX / Unix domain ==="; \
  grep -rn "AF_UNIX\|AF_LOCAL\|UnixSocket\|UnixDomain\|SockAddrUn" --include=*.rs . | head -20; \
  echo "(count:)"; grep -rn "AF_UNIX" --include=*.rs . | wc -l; \
  echo "=== net 相关目录 ==="; \
  ls posix/net/src/ 2>/dev/null; echo "---"; ls net/ 2>/dev/null; echo "---"; ls fs/filesystems/ 2>/dev/null; \
  echo "=== socket family 定义（AF_ 枚举）==="; \
  grep -rn "AF_INET\b" --include=*.rs posix/ net/ 2>/dev/null | head -8; \
  echo "=== 构建进度 ==="; tail -6 ~/xk6/tmp/build_xk.log; echo "-- FATAL:"; grep -c FATAL ~/xk6/tmp/build_xk.log; echo "-- DONE:"; grep -c BUILD_T490_DONE ~/xk6/tmp/build_xk.log'
