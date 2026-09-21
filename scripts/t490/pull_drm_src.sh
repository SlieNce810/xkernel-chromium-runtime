#!/usr/bin/env bash
# 从 T490 拉取 DRM 链路关键源码到本地分析（经 WSL 通道）
exec > /mnt/e/02_competition/中电杯/tmp/pull_src.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/tmp/xk-src-t490
mkdir -p "$DST"

$SSH mo@10.249.63.140 'cd ~/x-kernel && tar czf /tmp/xk6-src.tgz \
  io/drmdevice/src io/drmdevice/docs \
  fs/filesystems/devfs/src \
  drivers/contracts/display/docs \
  drivers/devices/virtio/src/gpu.rs \
  drivers/devices/virtio/src/input.rs 2>/dev/null; ls -la /tmp/xk6-src.tgz'

scp -o BatchMode=yes mo@10.249.63.140:/tmp/xk6-src.tgz "$DST/" && tar xzf "$DST/xk6-src.tgz" -C "$DST"
find "$DST" -type f | head -40
echo PULL_SRC_DONE
