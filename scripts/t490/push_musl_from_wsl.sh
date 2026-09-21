#!/usr/bin/env bash
# WSL -> T490 直传 musl 交叉工具链（T490 上 musl.cc 不可达，用 WSL 已下载的包）
exec > /mnt/e/02_competition/中电杯/tmp/push_musl.log 2>&1
set -x
# 1. 布署私钥到 WSL（从 Windows 侧复制，权限收紧）
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp -f /mnt/c/Users/12697/.ssh/id_ed25519 ~/.ssh/id_ed25519 2>/dev/null
chmod 600 ~/.ssh/id_ed25519
ls -l ~/.ssh/id_ed25519

# 2. 连通性
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 mo@10.249.63.140 'hostname; echo SSH_OK'

# 3. 传 musl tgz（103MB）
TGZ="$HOME/musl/aarch64-linux-musl-cross.tgz"
ls -la "$TGZ"
time scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TGZ" mo@10.249.63.140:/tmp/
ssh -o BatchMode=yes mo@10.249.63.140 'ls -la /tmp/aarch64-linux-musl-cross.tgz; sha256sum /tmp/aarch64-linux-musl-cross.tgz'
sha256sum "$TGZ"
echo PUSH_MUSL_DONE
