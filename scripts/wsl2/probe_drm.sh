#!/usr/bin/env bash
# 深挖 devfs 的 /dev/dri 节点注册与 card0 实现
exec > /mnt/e/02_competition/中电杯/tmp/probe_drm.log 2>&1
set -x
DST=/mnt/e/02_competition/中电杯/tmp/xk-dump
cd "$HOME/x-kernel" || exit 1

echo '=== devfs nodes 目录结构 ==='
ls fs/filesystems/devfs/src/nodes/ 2>/dev/null || ls fs/filesystems/devfs/src/

echo '=== dri 节点源码 ==='
find fs/filesystems/devfs/src -name '*.rs' | while read f; do
  if grep -q 'dri' "$f"; then
    echo "--- $f ---"
    cat "$f"
  fi
done

echo '=== drmdevice src ==='
ls io/drmdevice/src/
for f in io/drmdevice/src/*.rs; do
  echo "--- $f (头 120 行) ---"
  head -120 "$f"
done

echo '=== virtio-gpu 驱动里 card0/drm 注册点 ==='
grep -n 'card0\|DrmDevice\|drmdevice\|register' drivers/devices/virtio/src/gpu.rs | head -20

echo '=== fbdevice 与 drmdevice 的关系 ==='
grep -rn 'drmdevice\|card0' io/fbdevice/src/*.rs 2>/dev/null | head -10
echo PROBE_DONE
