#!/usr/bin/env bash
# 侦察：x-kernel 挂载 devfs/procfs 的位置（P1 sysfs 挂载点的添加位置）
exec > /mnt/e/02_competition/中电杯/tmp/mount_recon.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel && \
  echo "=== devfs 挂载调用点 ==="; \
  grep -rn "devfs::builder\|nodes::dri\|mount.*devfs\|DevfsBuilder\|builder(.*SimpleFs\|fs::devfs" --include=*.rs fs/ entry/ boot/ platforms/ 2>/dev/null | grep -v "^fs/filesystems/devfs/src" | head -20; \
  echo "=== 挂载流程入口（mount 函数/流程）==="; \
  grep -rln "fn mount_root\|mount_filesystems\|init_filesystems\|fs::mount\|MountPoint" --include=*.rs fs/ entry/ 2>/dev/null | head -10; \
  echo "=== devfs 的 DirMapping 用法（SysFs 可仿照）==="; \
  grep -rn "pub fn builder\|fn add_root_entries" fs/filesystems/devfs/src/*.rs | head -10; \
  echo "=== /sys 是否已被某处挂载 ==="; \
  grep -rn "\"/sys\"\|mount.*sys\|sysfs" --include=*.rs fs/ entry/ 2>/dev/null | head -10'
