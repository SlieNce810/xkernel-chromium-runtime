#!/bin/sh
set -u
echo "[autorun] sandboxipc probe start" > /dev/console
/sandboxipcprobe > /root/sandboxipcprobe.log 2>&1
cat /root/sandboxipcprobe.log > /dev/console 2>&1
