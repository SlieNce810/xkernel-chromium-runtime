#!/usr/bin/env bash
# P1 侦察 2：memfs 的 SYSFS_TYPE 定义与 builder 机制
exec > /mnt/e/02_competition/中电杯/tmp/p1_recon2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel
echo "=== memfs 里 SYSFS_TYPE 定义 ==="
grep -rn "SYSFS_TYPE" --include=*.rs fs/filesystems/memfs/ | head -10
echo "=== memfs/src 结构 ==="
ls fs/filesystems/memfs/src/
echo "=== memfs lib.rs 里 SYSFS 段 ==="
grep -n -B2 -A25 "SYSFS_TYPE" fs/filesystems/memfs/src/lib.rs | head -60
echo "=== memfs TMPFS_TYPE 对比（builder 机制）==="
grep -n -B2 -A20 "TMPFS_TYPE" fs/filesystems/memfs/src/lib.rs | head -50'
