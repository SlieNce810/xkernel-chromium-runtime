#!/usr/bin/env bash
# 固化：P0 commit + 镜像冻结
exec > /mnt/e/02_competition/中电杯/tmp/p0_freeze.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
# 0. 停会话
pkill -TERM -f qemu-system-aarch64 2>/dev/null || true
sleep 5
pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64 || true
pkill -f run-session.py 2>/dev/null || true
sleep 1
cd ~/x-kernel

# 1. e2fsck + 冻结镜像
e2fsck -f -y disk.img 2>&1 | tail -2
mkdir -p images
cp -f disk.img images/p0-drmversion-fixed.img
sha256sum images/p0-drmversion-fixed.img

# 2. P0 补丁 commit
git add io/drmdevice/src/card0.rs
git -c user.name="xk6-team" -c user.email="xk6@local" commit -m "fix(drm): tolerate NULL pointers in DRM_IOCTL_VERSION/DRM_UNIQUE

libdrm passes NULL pointers with zero lengths in its first
drmGetVersion()/drmGetBusid() call to query string sizes.
The unconditional copy_to_user returned EFAULT in that case,
breaking every libdrm client.

Only copy the string when the caller provided a buffer and cap
the copy at the user-supplied length (min semantics), mirroring
Linux drm_version handling.

Verified on kplat-aarch64 (QEMU TCG): drmprobe shows
drmGetVersion() now returns a valid drmVersionPtr with
driver simpledrm 1.0.0." 
git log --oneline -3

# 3. tag
git tag -f p0-drm-version-fix 2>/dev/null || true
git tag | tail -3
echo P0_FREEZE_OK'
