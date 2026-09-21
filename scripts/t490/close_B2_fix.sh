#!/usr/bin/env bash
# 修正：把 evidence/evidence/* 上移一层
exec > /mnt/e/02_competition/中电杯/tmp/close_B2.log 2>&1
set -x
cd "/mnt/e/02_competition/中电杯/evidence" || exit 1
mv evidence/2026-09-21_t490-* . 2>/dev/null
rmdir evidence 2>/dev/null
echo "=== 会话目录 ==="
ls -d 2026-09-21_t490-*/ | wc -l
ls -d 2026-09-21_t490-*/
echo "=== PPM 计数 ==="
find 2026-09-21_t490-* -name "*.ppm" | wc -l
echo "=== console.log 计数 ==="
find 2026-09-21_t490-* -name "console.log" | wc -l
echo "=== 每会话文件构成（前 3 个会话示例）==="
for d in 2026-09-21_t490-diag1 2026-09-21_t490-v16-final 2026-09-21_t490-p0-fix; do
  echo "--- $d"
  ls -la "$d" 2>/dev/null | head -8
done
echo "=== 体积 ==="
du -sh . 
