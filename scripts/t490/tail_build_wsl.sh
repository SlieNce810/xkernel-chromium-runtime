#!/usr/bin/env bash
# 通过 WSL 内的 ssh 读取 T490 构建进度（绕开 Windows .ssh 沙箱路径）
exec > /mnt/e/02_competition/中电杯/tmp/t490_build_status.txt 2>&1
ssh -o BatchMode=yes -o ConnectTimeout=10 mo@10.249.63.140 'echo "=== tail 30 ==="; tail -30 ~/xk6/tmp/build_xk.log; echo "=== FATAL count ==="; grep -c FATAL ~/xk6/tmp/build_xk.log; echo "=== DONE marker ==="; grep -c BUILD_T490_DONE ~/xk6/tmp/build_xk.log'
