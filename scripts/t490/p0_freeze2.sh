#!/usr/bin/env bash
# 分步固化：每步独立 ssh，明确输出
exec > /mnt/e/02_competition/中电杯/tmp/p0_freeze2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

echo "=== STEP1: stop qemu ==="
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 4; pkill -KILL -f qemu-system-aarch64 2>/dev/null; pkill -f run-session.py 2>/dev/null; sleep 1; echo STOP_OK'
sleep 2

echo "=== STEP2: e2fsck ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'

echo "=== STEP3: freeze image ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && cp -f disk.img images/p0-drmversion-fixed.img && ls -la images/ && echo CP_OK'

echo "=== STEP4: git commit ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && git add io/drmdevice/src/card0.rs && git -c user.name=xk6 -c user.email=xk6@local commit -m "fix(drm): tolerate NULL pointers in DRM_IOCTL_VERSION and DRM_UNIQUE" && git log --oneline -2'

echo "=== STEP5: tag ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && git tag p0-drm-version-fix && git tag'

echo "=== STEP6: verify ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && git log --oneline -2 && ls -la images/ && sha256sum images/p0-drmversion-fixed.img'
echo FREEZE2_DONE
