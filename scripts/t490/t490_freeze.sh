#!/usr/bin/env bash
# 补做：冻结 T490 调试镜像
exec > /mnt/e/02_competition/中电杯/tmp/t490_freeze.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel && mkdir -p images && cp -f disk.img images/dev-t490-debug-baseline.img && ls -la images/ && sha256sum images/dev-t490-debug-baseline.img && echo FREEZE_OK'
