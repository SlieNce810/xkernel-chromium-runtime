#!/usr/bin/env bash
# QEMU 源码获取路线探测
exec > /mnt/e/02_competition/中电杯/tmp/probe_net.log 2>&1
echo '--- HTTP probes ---'
curl -s -o /dev/null -w 'github.com        %{http_code} %{time_total}s\n' --max-time 10 https://github.com
curl -s -o /dev/null -w 'codeload.github   %{http_code} %{time_total}s\n' --max-time 10 https://codeload.github.com
curl -s -o /dev/null -w 'gitee mirrors/qemu %{http_code} %{time_total}s\n' --max-time 10 https://gitee.com/mirrors/qemu
echo '--- git ls-remote github (timeout 25s) ---'
timeout 25 git ls-remote --tags https://github.com/qemu/qemu refs/tags/v8.2.3 2>&1 | head -3
echo "rc=$?"
echo '--- git ls-remote gitee mirror (timeout 25s) ---'
timeout 25 git ls-remote https://gitee.com/mirrors/qemu.git HEAD 2>&1 | head -3
echo "rc=$?"
echo '--- pip meson availability ---'
pip3 --version 2>&1 | head -1
echo 'PROBE_DONE'
