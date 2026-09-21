#!/usr/bin/env bash
# 打印 fs/boot/src/lib.rs 的挂载段（devfs/procfs 挂载方式）
exec > /mnt/e/02_competition/中电杯/tmp/mount_recon2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel && \
  echo "=== fs/boot/src/lib.rs 结构 ==="; wc -l fs/boot/src/lib.rs; \
  echo "=== 100-200 行（挂载段）==="; sed -n "100,200p" fs/boot/src/lib.rs; \
  echo "=== mount 函数定义点 ==="; grep -n "pub fn mount\|fn mount\|fn bootstrap\|pub fn init" fs/boot/src/lib.rs | head -10'
