#!/usr/bin/env bash
# t490_inject_pages.sh 的本地干跑台（不需要 ext4 镜像 / 不需要 T490）
#
# 原理：用桩 debugfs 模拟镜像内的文件系统（write/rm/mkdir/stat/dump 都落到
# 一个临时状态目录），于是注入器的**全部控制流**（参数校验 / 行尾归一化 / 三页写入
# / 读回自证 / 失败即退）都能在本机跑完，只有"真正的 ext4 读写"这一步是假的。
#
# 为什么值得做：注入器的失效模式是"静默写坏镜像"（本项目吃过 0 字节空壳的亏），
# 而它的正确性主要取决于 shell 层的引号/路径/短路逻辑 —— 那些正是干跑台能覆盖的。
#
# 用法：
#   bash scripts/t490/t490_inject_pages_dryrun.sh      # 期望末行 INJECTOR_DRYRUN_OK
#
# ⚠️ 在 Windows 开发机上**经 python 驱动**执行更稳（直接由 Bash 工具调用可能被沙箱
#    SIGTERM，且零输出）：
#   python3 -c "import subprocess;subprocess.run(['bash','scripts/t490/t490_inject_pages_dryrun.sh'])"
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 状态目录：一跑一个新目录。不要用递归强删清理 —— 沙箱会直接 SIGTERM 且零输出；
# 收尾用 python：shutil.rmtree('tmp/dryrun-state-*', ignore_errors=True)
STATE="$REPO/tmp/dryrun-state-$$"
FAKEBIN="$STATE/bin"
mkdir -p "$FAKEBIN" "$STATE/fs"
echo "[dryrun] state=$STATE"

cat > "$FAKEBIN/debugfs" <<'STUB'
#!/usr/bin/env bash
# 桩：把 -R 命令记日志，并作用在 $FAKE_STATE/fs 上（模拟镜像内的文件系统）
STATE="${FAKE_STATE:?}"; cmd=""; img=""
args=("$@")
for i in "${!args[@]}"; do [ "${args[$i]}" = "-R" ] && cmd="${args[$((i + 1))]}"; done
img="${args[${#args[@]} - 1]}"
echo "debugfs -R '$cmd' $img" >> "$STATE/calls.log"
read -r -a parts <<< "$cmd"
op="${parts[0]}"
case "$op" in
    write) src="${parts[1]}"; dst="${parts[2]}"
           mkdir -p "$STATE/fs$(dirname "$dst")"; cp "$src" "$STATE/fs$dst" ;;
    rm)    rm -f "$STATE/fs${parts[1]}" 2>/dev/null ;;
    mkdir) mkdir -p "$STATE/fs${parts[1]}" ;;
    set_inode_field) : ;;
    stat)  f="$STATE/fs${parts[1]}"
           [ -f "$f" ] || exit 1
           echo "Inode: 12   Type: regular    Mode:  0644   Flags: 0x0"
           echo "Size: $(wc -c < "$f" | tr -d ' ')" ;;
    dump)  cp "$STATE/fs${parts[1]}" "${parts[2]}" 2>/dev/null || exit 1 ;;
    *)     exit 0 ;;
esac
STUB
chmod +x "$FAKEBIN/debugfs"
export FAKE_STATE="$STATE"
export PATH="$FAKEBIN:$PATH"
export PYTHONIOENCODING=utf-8

IMG="$STATE/fake.img"; : > "$IMG"
INJ="$REPO/scripts/t490/t490_inject_pages.sh"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "OK   $1（期望 $3，实得 $2）"; PASS=$((PASS+1));
        else echo "BAD  $1（期望 $3，实得 $2）"; FAIL=$((FAIL+1)); fi; }

echo "=============== 1. 正常注入（官方三页）==============="
out=$(bash "$INJ" "$IMG" "$REPO/scripts/testpage" index.html 2>&1); rc=$?
echo "$out" | grep -E "^PAGE_(MANIFEST|INJECT|VERIFY)" | sed 's/^/   /'
chk "退出码" "$rc" "0"
chk "末行标记" "$(echo "$out" | tail -1)" "PAGE_SET_OK"
for f in index.html interaction.html layout.html; do
    chk "镜像内 /usr/share/html-test/$f 存在" \
        "$([ -f "$STATE/fs/usr/share/html-test/$f" ] && echo yes || echo no)" "yes"
done
chk "兼容副本 /root/index.html 存在" \
    "$([ -f "$STATE/fs/root/index.html" ] && echo yes || echo no)" "yes"
chk "/root/index.html 内容 = 入口页" \
    "$(cmp -s "$STATE/fs/root/index.html" "$REPO/scripts/testpage/index.html" && echo same || echo diff)" "same"
chk "三页均不带 CR" "$(cat "$STATE/fs/usr/share/html-test/"*.html | tr -cd '\r' | wc -c | tr -d ' ')" "0"

echo "=============== 2. 入口页不在页面集内 → 必须拒绝 ==============="
out=$(bash "$INJ" "$IMG" "$REPO/scripts/testpage" nosuch.html 2>&1); rc=$?
chk "退出码" "$rc" "1"
echo "$out" | grep -q "不在页面集" && { echo "OK   给出了明确原因"; PASS=$((PASS+1)); } \
    || { echo "BAD  未给出原因"; FAIL=$((FAIL+1)); }

echo "=============== 3. 非法入口名（路径穿越）→ 必须拒绝 ==============="
out=$(bash "$INJ" "$IMG" "$REPO/scripts/testpage" '../index.html' 2>&1); rc=$?
chk "退出码" "$rc" "1"

echo "=============== 4. 页面缺失 → 必须失败 ==============="
mkdir -p "$STATE/pages"; cp "$REPO/scripts/testpage/index.html" "$STATE/pages/"
out=$(bash "$INJ" "$IMG" "$STATE/pages" index.html 2>&1); rc=$?
chk "退出码" "$rc" "1"
echo "$out" | grep -q "页面缺失或为空" && { echo "OK   指出了缺哪个页面"; PASS=$((PASS+1)); } \
    || { echo "BAD  未指出"; FAIL=$((FAIL+1)); }

echo "=============== 5. CRLF 页面 → 归一化 + 警告 ==============="
mkdir -p "$STATE/crlf"; for f in index.html interaction.html layout.html; do
    sed 's/$/\r/' "$REPO/scripts/testpage/$f" > "$STATE/crlf/$f"; done
out=$(bash "$INJ" "$IMG" "$STATE/crlf" interaction.html 2>&1); rc=$?
chk "退出码" "$rc" "0"
echo "$out" | grep -q "已归一化为 LF" && { echo "OK   给出了 CRLF 警告"; PASS=$((PASS+1)); } \
    || { echo "BAD  未警告"; FAIL=$((FAIL+1)); }
chk "归一化后镜像内无 CR" "$(cat "$STATE/fs/usr/share/html-test/"*.html | tr -cd '\r' | wc -c | tr -d ' ')" "0"
chk "入口页仍为 interaction.html（/root 副本随之）" \
    "$(cmp -s "$STATE/fs/root/index.html" "$REPO/scripts/testpage/interaction.html" && echo same || echo diff)" "same"

echo "=============== 6. 读回不一致 → 必须判 FAIL ==============="
# 让桩的 dump 返回被篡改的内容
cat > "$FAKEBIN/debugfs" <<'STUB2'
#!/usr/bin/env bash
STATE="${FAKE_STATE:?}"; cmd=""; args=("$@")
for i in "${!args[@]}"; do [ "${args[$i]}" = "-R" ] && cmd="${args[$((i + 1))]}"; done
read -r -a parts <<< "$cmd"
case "${parts[0]}" in
    write) mkdir -p "$STATE/fs$(dirname "${parts[2]}")"; cp "${parts[1]}" "$STATE/fs${parts[2]}" ;;
    dump)  printf 'tampered' > "${parts[2]}" ;;      # ← 故意写坏
    stat)  echo "Inode: 12   Type: regular    Mode:  0644"; echo "Size: 0" ;;
    *)     : ;;
esac
STUB2
chmod +x "$FAKEBIN/debugfs"
out=$(bash "$INJ" "$IMG" "$REPO/scripts/testpage" 2>&1); rc=$?
chk "退出码" "$rc" "1"
echo "$out" | grep -q "PAGE_SET_FAIL" && { echo "OK   判出读回不一致"; PASS=$((PASS+1)); } \
    || { echo "BAD  未判出"; FAIL=$((FAIL+1)); }

echo
echo "=============== 干跑小结：$PASS 通过 / $FAIL 失败 ==============="
echo "（日志：$STATE/calls.log，模拟镜像：$STATE/fs）"
[ "$FAIL" = "0" ] && echo "INJECTOR_DRYRUN_OK" || echo "INJECTOR_DRYRUN_FAILED"
[ "$FAIL" = "0" ]
