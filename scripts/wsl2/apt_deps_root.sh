#!/usr/bin/env bash
# 安装 QEMU 编译依赖（root 阶段，WSL -u root 执行）
exec > /mnt/e/02_competition/中电杯/tmp/apt_deps.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ninja-build \
  libglib2.0-dev \
  libpixman-1-dev \
  zlib1g-dev \
  libfdt-dev \
  libslirp-dev
echo "APT_DEPS_DONE rc=$?"
