#!/usr/bin/env bash
# 检查 WSL 内 QEMU 会话是否存活
exec > /mnt/e/02_competition/中电杯/tmp/alive_check.log 2>&1
pgrep -a -f qemu-system-aarch64 | head -3 || echo NO-QEMU
pgrep -a -f run-session.py | head -3 || echo NO-SESSION
date
