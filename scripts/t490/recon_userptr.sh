#!/usr/bin/env bash
# 只读侦察：UserPtr 的空指针判断 API + devfs/procfs 的 Cargo.toml + workspace 结构
exec > /mnt/e/02_competition/中电杯/tmp/recon_userptr.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel
echo "=== UserPtr 定义文件 ==="
grep -rln "pub struct UserPtr" --include=*.rs posix/ | head -3
F=$(grep -rln "pub struct UserPtr" --include=*.rs posix/ | head -1)
echo "--- $F 关键片段 ---"
grep -n "pub fn \|impl.*UserPtr" "$F" | head -25
echo "=== as_ptr/is_null ==="
grep -n "fn is_null\|fn as_ptr\|fn addr" "$F" | head -10
echo "=== devfs Cargo.toml ==="
cat fs/filesystems/devfs/Cargo.toml
echo "=== 顶层 workspace members 片段 ==="
grep -n -A3 "members" Cargo.toml | head -15
echo "=== fs/boot Cargo.toml 依赖片段 ==="
grep -n "devfs\|procfs\|memfs" fs/boot/Cargo.toml | head -8
echo "=== kvfs 导出（SimpleDir/DirMapping/文件创建原语）==="
grep -n "pub use\|pub mod" fs/kvfs/src/lib.rs | head -20
echo "=== procfs 的简单只读文件范例（stat.rs 或 version）==="
ls fs/filesystems/procfs/src/nodes/ 2>/dev/null | head -15'
