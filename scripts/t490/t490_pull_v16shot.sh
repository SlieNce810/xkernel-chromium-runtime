#!/usr/bin/env bash
# 拉 v16 最新截图并转 PNG
exec > /mnt/e/02_competition/中电杯/tmp/t490_pull_v16shot.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/tmp/t490-evidence
mkdir -p "$DST"
SHOTDIR=$($SSH mo@10.249.63.140 'ls -td ~/xk6/evidence/*/screenshots/ | head -1' | tr -d '\r')
scp -o BatchMode=yes "mo@10.249.63.140:${SHOTDIR}shot-04-at0165s.ppm" "$DST/v16-shot-04.ppm"
scp -o BatchMode=yes "mo@10.249.63.140:${SHOTDIR}shot-03-at0125s.ppm" "$DST/v16-shot-03.ppm"
ls -la "$DST"/v16-shot*.ppm
echo PULLED
