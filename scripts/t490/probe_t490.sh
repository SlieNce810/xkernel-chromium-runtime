#!/bin/sh
# T490 环境探测（用户级，无需 sudo）
echo "=== APT QEMU CANDIDATE ==="
apt-cache policy qemu-system-arm 2>/dev/null | head -8
echo "=== SUDO ==="
sudo -n true 2>/dev/null && echo "sudo NOPASSWD" || echo "sudo NEEDS_PASSWORD"
echo "=== EXTRA TOOLS ==="
for t in rsync unzip ninja-build meson pkg-config file cpio sha256sum; do
  printf "%-14s " "$t"
  command -v "$t" >/dev/null 2>&1 && echo OK || echo MISSING
done
echo "=== NET ==="
curl -fsSL -o /dev/null -w 'gitee      %{http_code} %{time_total}s\n' --max-time 12 https://gitee.com 2>&1
curl -fsSL -o /dev/null -w 'rustup.rs  %{http_code} %{time_total}s\n' --max-time 12 https://sh.rustup.rs 2>&1
curl -fsSL -o /dev/null -w 'musl.cc    %{http_code} %{time_total}s\n' --max-time 12 https://musl.cc 2>&1
curl -fsSL -o /dev/null -w 'github     %{http_code} %{time_total}s\n' --max-time 12 https://github.com 2>&1
echo "=== LIB DEPS（QEMU 运行/编译所需）==="
dpkg -l 2>/dev/null | grep -E 'libglib2.0-0|libpixman-1-0|libslirp0|libfdt1' | awk '{print $2, $3}'
echo "=== CARGO HOME ==="
echo "HOME=$HOME"; ls -d ~/.cargo ~/.rustup 2>/dev/null || echo "no rustup dirs"
echo "=== CPU 型号 ==="
grep -m1 'model name' /proc/cpuinfo
echo PROBE_DONE
