#!/usr/bin/env bash
# P1 侦察：fs/boot/src/lib.rs 的 /proc 挂载段、MOUNT_FLAGS 常量、root.rs 结尾
exec > /mnt/e/02_competition/中电杯/tmp/p1_recon.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel
echo "=== fs/boot/src/lib.rs: 195-240 行（/proc 挂载段收尾）==="
sed -n "195,240p" fs/boot/src/lib.rs
echo "=== MOUNT_FLAGS 常量定义 ==="
grep -n "MOUNT_FLAGS\|use kvfs" fs/boot/src/lib.rs | head -12
echo "=== devfs/src/root.rs 结尾（DirMaker 构造）==="
tail -20 fs/filesystems/devfs/src/root.rs
echo "=== 顶层 Cargo.toml 的 fs/filesystems members + workspace.dependencies fs 条目 ==="
grep -n "fs/filesystems" Cargo.toml | head -10
grep -n "devfs = \|procfs = \|memfs = " Cargo.toml | head -6
echo "=== devfs/src/root.rs 全文行数 ==="
wc -l fs/filesystems/devfs/src/root.rs'
