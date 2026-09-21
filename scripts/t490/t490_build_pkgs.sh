#!/usr/bin/env bash
# T490 宿主机：跨架构（aarch64）预装 fontconfig / 字体 / Chromium，并打成**单个 tar.gz**
#
# 背景（2026-09-21 新发现）
# ----------------------
# P0 冻结镜像里"apk 预装"那批文件全是 **0 字节空壳**：
#     /usr/share/fonts/noto/NotoSansCJK-Regular.ttc   Size 0 / Blockcount 0
#     /usr/share/fonts/opensans/OpenSans-Regular.ttf  Size 0 / Blockcount 0
#     /usr/lib/chromium/chromium                      Size 0 / Blockcount 0
#     /etc/fonts/fonts.conf                           Size 0 → Fontconfig "line 1: no element found"
# 而 /usr/bin/weston 是 67240 字节（真实），所以图形链能跑、浏览器链不能。
# guest 侧网络实测不可达（eth0 有 10.0.2.15、DNS 10.0.2.3，但取包 0 字节），
# 所以只能走宿主侧预装。
#
# 为什么打成 tar.gz 再注入
# -----------------------
# 用 debugfs 逐文件注入几百个文件，符号链接 / 权限 / 硬链接极易出错
# （debugfs 的 write 只能写普通文件）。改为：
#     宿主 apk 装到临时根 → tar 打包 → 注入**一个** tar 文件 → guest 内 tar -x 解开
# 由 tar 保证 symlink / mode / hardlink 全部保真。
#
# 产物：~/xk6/tmp/pkgs-fetch.tar.gz + 同名 .list（内容清单）与 .sha256

set -xe

WORK="$HOME/xk6/tmp"
# ★ 镜像选择（2026-09-21 T490 实测下载速度）：
#   mirrors.aliyun.com        932 KB/s   ← 用这个
#   mirror.nju.edu.cn          57 KB/s
#   dl-cdn.alpinelinux.org     32 KB/s
#   mirrors.cernet.edu.cn      ~0.5 KB/s（且 302）
# 用 dl-cdn 时 2.2 MB 的 apk-tools-static 都下不完（180s 超时），必须换源。
MIR="https://mirrors.aliyun.com/alpine/v3.23"
MIRX="$MIR/main/x86_64"
APKROOT="$WORK/xkroot-fetch"
TARBALL="$WORK/pkgs-fetch.tar.gz"

mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- 1. apk-tools-static（宿主 x86_64）
if [ ! -x "$WORK/apkstatic/sbin/apk.static" ]; then
    echo "=== 取 apk-tools-static ==="
    APKT=$(curl -sL --max-time 30 "$MIRX/" | grep -oE 'apk-tools-static-[0-9][^"]*\.apk' | sort -u | head -1)
    echo "APKT=$APKT"
    curl -fL --retry 3 --retry-delay 2 --max-time 600 --speed-time 60 --speed-limit 1024 \
        -o apk-tools-static.apk "$MIRX/$APKT"
    rm -rf apkstatic && mkdir -p apkstatic
    tar -xzf apk-tools-static.apk -C apkstatic
fi
APK="$WORK/apkstatic/sbin/apk.static"
"$APK" --version

# ---------------------------------------------------------------- 2. 包名确认（直接解析 APKINDEX）
# 注意：**不要用 `apk search` 做存在性判断**。apk-tools 3.x 在索引签名不受信时
# 只打印 "UNTRUSTED signature" 警告并 rc=1、无输出，导致所有包都被判为不存在
# （本轮第一版就因此把 chromium 整包漏掉了）。直接解析 APKINDEX.tar.gz 才可靠。
echo "=== 拉取并解析 APKINDEX ==="
curl -sL --retry 3 --max-time 300 "$MIR/main/aarch64/APKINDEX.tar.gz" -o /tmp/idx-main.tgz
curl -sL --retry 3 --max-time 300 "$MIR/community/aarch64/APKINDEX.tar.gz" -o /tmp/idx-comm.tgz
tar -xzOf /tmp/idx-main.tgz APKINDEX 2>/dev/null | grep '^P:' | cut -d: -f2 > /tmp/pkgs-main.txt
tar -xzOf /tmp/idx-comm.tgz APKINDEX 2>/dev/null | grep '^P:' | cut -d: -f2 > /tmp/pkgs-comm.txt
cat /tmp/pkgs-main.txt /tmp/pkgs-comm.txt | sort -u > /tmp/pkgs-all.txt
echo "main 包数=$(wc -l < /tmp/pkgs-main.txt)  community 包数=$(wc -l < /tmp/pkgs-comm.txt)"

# ---------------------------------------------------------------- 3. 组装包列表
PKGS="fontconfig"
for p in font-opensans font-noto font-noto-cjk chromium chromium-swiftshader; do
    if grep -qx "$p" /tmp/pkgs-all.txt; then
        PKGS="$PKGS $p"
        echo "  OK   $p"
    else
        echo "  MISS $p （该分支无此包，跳过）"
    fi
done
echo "PKGS=$PKGS"

# ---------------------------------------------------------------- 4. 装到临时根
rm -rf "$APKROOT"
mkdir -p "$APKROOT"
"$APK" --usermode --arch aarch64 --root "$APKROOT" \
    --repository "$MIR/main" --repository "$MIR/community" \
    --allow-untrusted --no-scripts --initdb \
    add $PKGS 2>&1 | tail -60

# ---------------------------------------------------------------- 5. 产物检查（关键文件必须非空）
echo "=== 关键文件实体检查 ==="
for f in usr/lib/chromium/chromium usr/bin/chromium etc/fonts/fonts.conf; do
    if [ -e "$APKROOT/$f" ]; then
        printf '%-46s %s\n' "$f" "$(stat -c '%s bytes mode=%a type=%F' "$APKROOT/$f" 2>/dev/null)"
    else
        printf '%-46s MISSING\n' "$f"
    fi
done
# 字体按目录列举（不同包路径不同，别硬编码单个文件名）
echo "--- 字体文件（前 12 个）---"
find "$APKROOT/usr/share/fonts" -type f \( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \) 2>/dev/null | head -12 || true
echo "字体文件总数: $(find "$APKROOT/usr/share/fonts" -type f 2>/dev/null | wc -l)"
echo "=== 体积 ==="
du -sh "$APKROOT"

# ---------------------------------------------------------------- 6. 打包
echo "=== 打包 ==="
tar -czf "$TARBALL" -C "$APKROOT" .
ls -la "$TARBALL"
sha256sum "$TARBALL" | tee "$TARBALL.sha256"
echo "条目数:      $(tar -tzf "$TARBALL" | wc -l)"
echo "符号链接数:  $(tar -tvzf "$TARBALL" | grep -c '^l')"
echo "可执行数:    $(tar -tvzf "$TARBALL" | grep -c '^-rwx')"

echo BUILD_PKGS_DONE
