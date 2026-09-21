#!/usr/bin/env bash
# 收口E：T490 清理（先列清单，再删，最后复核）
exec > /mnt/e/02_competition/中电杯/tmp/close_E.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 '
set -u
echo "=== 全盘占用（清理前）==="
df -h /home | tail -1

echo ""
echo "=== ① 将删除：/tmp 大文件 ==="
ls -la /tmp/wsl-weston.img /tmp/disk-t490-built.img /tmp/aarch64-linux-musl-cross.tgz /tmp/xk6-scripts.tgz /tmp/xk6-src.tgz /tmp/t490-evidence.tgz 2>/dev/null
echo "=== ② 将删除：/tmp 临时脚本/探针 ==="
ls -la /tmp/*.sh /tmp/*.py /tmp/drmprobe* /tmp/libseat-shim.so /tmp/*.log 2>/dev/null | head -20
echo "=== ③ 将删除：~/xk6/tmp 中间产物 ==="
du -sh ~/xk6/tmp/* 2>/dev/null

echo ""
echo "=== 执行删除 ==="
# 先保底：把仅存于 /tmp 的脚本回收到 ~/xk6/scripts/t490
cp -n /tmp/modify_card0.py ~/xk6/scripts/t490/ 2>/dev/null || true
cp -n /tmp/probe_t490.sh ~/xk6/scripts/t490/ 2>/dev/null || true

rm -f /tmp/wsl-weston.img /tmp/disk-t490-built.img /tmp/aarch64-linux-musl-cross.tgz
rm -f /tmp/xk6-scripts.tgz /tmp/xk6-src.tgz /tmp/t490-evidence.tgz
rm -f /tmp/*.sh /tmp/*.py /tmp/*.log /tmp/drmprobe /tmp/drmprobe2 /tmp/drmprobe3 /tmp/libseat-shim.so
rm -rf ~/xk6/tmp/rootfs-w10 ~/xk6/tmp/apk ~/xk6/tmp/apkstatic ~/xk6/tmp/fakesys ~/xk6/tmp/alpine-root
rm -f ~/xk6/tmp/*.tgz ~/xk6/tmp/*.img
echo "删除完成"

echo ""
echo "=== 复核 ==="
echo "--- 全盘占用（清理后）---"
df -h /home | tail -1
echo "--- /tmp 剩余 ---"
ls -la /tmp | head -12
echo "--- ~/xk6/tmp 剩余 ---"
ls -la ~/xk6/tmp 2>/dev/null | head -8
echo "--- 冻结镜像校验（应未被误伤）---"
cd ~/x-kernel && sha256sum images/*.img
echo "--- 残留进程 ---"
pgrep -c -f qemu-system-aarch64 2>/dev/null || echo 0
echo "--- 关键资产存在性 ---"
for p in ~/x-kernel/xkernel_aarch64-qemu.bin ~/xk6/evidence ~/xk6/scripts/t490/autorun_v5.sh ~/qemu-root/usr/bin/qemu-system-aarch64 ~/musl/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc; do
  [ -e "$p" ] && echo "OK   $p" || echo "MISS $p"
done
echo CLOSE_E_DONE'
