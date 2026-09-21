#!/usr/bin/env bash
# 收口B：证据全量打包 + 拉回本地 + 解包校验
exec > /mnt/e/02_competition/中电杯/tmp/close_B.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/evidence
mkdir -p "$DST"

# 1. T490 打包
$SSH mo@10.249.63.140 'cd ~/xk6 && rm -f /tmp/t490-evidence.tgz && tar czf /tmp/t490-evidence.tgz evidence/ && ls -la /tmp/t490-evidence.tgz && echo "T490 内文件数: $(tar tzf /tmp/t490-evidence.tgz | wc -l)" && sha256sum /tmp/t490-evidence.tgz'

# 2. 拉回本地
scp -o BatchMode=yes mo@10.249.63.140:/tmp/t490-evidence.tgz /mnt/e/02_competition/中电杯/tmp/t490-evidence.tgz
sha256sum /mnt/e/02_competition/中电杯/tmp/t490-evidence.tgz

# 3. 解包到本地 evidence/
tar xzf /mnt/e/02_competition/中电杯/tmp/t490-evidence.tgz -C "$DST" --exclude='2026-09-20_*' 2>/dev/null || tar xzf /mnt/e/02_competition/中电杯/tmp/t490-evidence.tgz -C "$DST"

# 4. 校验
echo "=== 本地会话目录 ==="
ls -d "$DST"/2026-09-21_t490-*/ | wc -l
ls -d "$DST"/2026-09-21_t490-*/
echo "=== 本地 PPM 计数 ==="
find "$DST"/2026-09-21_t490-* -name "*.ppm" | wc -l
echo "=== 本地 console.log 计数 ==="
find "$DST"/2026-09-21_t490-* -name "console.log" | wc -l
echo CLOSE_B_DONE
