#!/usr/bin/env bash
# 清理残留 QEMU/会话进程 + 查看 x-kernel DRM/autostart 相关源码
exec > /mnt/e/02_competition/中电杯/tmp/cleanup_and_probe.log 2>&1
set -x
# 1. 清理（只杀本任务启动的进程，不碰 Docker 等其他东西）
pkill -f 'qemu-system-aarch64' && echo killed-qemu || echo no-qemu
pkill -f 'run-session.py' && echo killed-session || echo no-session
sleep 1
pgrep -a -f qemu-system-aarch64 || echo 'qemu clear'

# 2. uapps autostart 注册逻辑（99-autostart.sh 如何生成）
DST=/mnt/e/02_competition/中电杯/tmp/xk-dump
cd "$HOME/x-kernel" || exit 1
for f in uapps/weston-start/manifest.toml uapps/weston-start/main.sh \
         uapps/hello/manifest.toml xtask/uapp/src/main.rs; do
  [ -f "$f" ] && cp "$f" "$DST/$(echo "$f" | tr '/' '_')" && echo "copied $f"
done

# 3. DRM 设备节点创建逻辑速览
ls io/drmdevice/
grep -n 'card0\|/dev/dri\|mknod\|device_register\|DrmDevice' io/drmdevice/*.rs | head -30
grep -rn 'card0' io/drmdevice/docs/design.md | head -10

# 4. devfs：/dev 下注册了哪些设备
grep -rn 'dri\|card' fs/filesystems/devfs/src/*.rs 2>/dev/null | head -20
echo PROBE_DONE
