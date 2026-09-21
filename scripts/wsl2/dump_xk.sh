#!/usr/bin/env bash
# dump x-kernel 关键文件到工作区供分析
DST=/mnt/e/02_competition/中电杯/tmp/xk-dump
mkdir -p "$DST"
cd "$HOME/x-kernel" || exit 1
for f in README.md Makefile xkmake platforms/kplat-aarch64/qemu_defconfig \
         uapps/weston-start/xk-weston-start docs/README.md; do
  if [ -f "$f" ]; then
    out="$DST/$(echo "$f" | tr '/' '_')"
    cp "$f" "$out"
    echo "copied: $f ($(wc -c < "$f") bytes)"
  else
    echo "MISSING: $f"
  fi
done
echo '--- top level ---'
ls -la | head -40
echo '--- Makefile targets ---'
grep -nE '^[a-zA-Z0-9_-]+:' Makefile | head -40
echo 'DUMP_DONE'
