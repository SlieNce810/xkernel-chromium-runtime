#!/usr/bin/env bash
# 测试页注入器 —— 把「组委会测试页三件套」**整套**写进 guest 镜像
#
# 用法：
#   bash t490_inject_pages.sh <disk.img> [page_dir] [entry]
#
# 参数：
#   <disk.img>  目标镜像（原地修改；调用方负责先 cp 基底镜像）
#   page_dir    页面集目录，默认 ~/xk6/scripts/testpage
#   entry       入口页文件名，默认 index.html（须是页面集成员）
#
# 环境变量：
#   PAGE_FILES  页面集清单（空格分隔），默认 "index.html interaction.html layout.html"
#
# 为什么必须**整套**注入，而不是只写一个 index.html：
#   官方三页互相有超链接（interaction.html ↔ layout.html），只注入其中一个会让
#   "页面跳转"直接 404 —— 而页面跳转本身就是决赛功能项（interaction.html 第 3 条）。
#   旧流程 `PAGE_HTML=<单文件> → /usr/share/html-test/index.html` 天然表达不了页面集。
#
# 落点（guest 内）：
#   /usr/share/html-test/<name>.html   三个页面，mode 0644
#   /root/index.html                   入口页副本（兼容早期只认这个路径的 autorun）
#
# 产出（stdout）：
#   PAGE_MANIFEST …   机器可读的一行清单头
#   PAGE_INJECT  …    逐页 注入结果：size / sha256
#   PAGE_VERIFY  …    逐页 读回比对结果：OK / FAIL（debugfs dump 后与源文件 cmp）
#   exit 0 = 全部读回一致；1 = 任一环节失败（调用方必须硬失败，不得带病起会话）
#
# 三条硬约束（都来自本项目的实测教训）：
#   1. 写盘前 `tr -d '\r'`：宿主侧编辑过的 HTML 可能带 CRLF，进 guest 会出现杂散字符；
#   2. 写完必须**读回比对**：本项目已经吃过"镜像里 chromium 是 0 字节空壳"的亏
#      （见 report/22），"写了"不等于"写对了"，所以这里用 dump + cmp 自证；
#   3. 入口页必须在页面集内：否则注入出的镜像会启动到一个不存在的文件上，
#      而症状（白屏）与"渲染失败"无法区分 —— 属于最贵的一类假阴性。
set -u
set -o pipefail

IMG="${1:?用法: t490_inject_pages.sh <disk.img> [page_dir] [entry]}"
PAGE_DIR="${2:-$HOME/xk6/scripts/testpage}"
ENTRY="${3:-index.html}"
PAGE_FILES="${PAGE_FILES:-index.html interaction.html layout.html}"
DEST_DIR="/usr/share/html-test"

[ -f "$IMG" ] || { echo "!! 镜像不存在: $IMG"; exit 1; }
[ -d "$PAGE_DIR" ] || { echo "!! 页面集目录不存在: $PAGE_DIR"; exit 1; }

# ---- 1. 入口页白名单 -------------------------------------------------------
# 入口名只允许页面集成员 + 保守字符集，杜绝把 `..`、空白或 shell 元字符带进
# 下面的 debugfs / sed 命令串。
case "$ENTRY" in
    *[!A-Za-z0-9._-]*|*..*) echo "!! 入口页名含非法字符: $ENTRY"; exit 1 ;;
esac
case " $PAGE_FILES " in
    *" $ENTRY "*) ;;
    *) echo "!! 入口页 $ENTRY 不在页面集 [$PAGE_FILES] 内"; exit 1 ;;
esac

# ---- 2. 逐页预检 + 行尾归一化（暂存区 = 唯一可信写盘源）--------------------
# 暂存区刻意用**固定路径 + 覆盖式写入 + 全程不删除**：
#   ① 开发机的沙箱对"通配符 + 删除循环"零容忍，实测直接 SIGTERM 且整条命令
#      没有任何输出（2026-09-22 排查记录：单文件 `rm -f` 可以，glob 循环删不行）；
#   ② 固定路径天然不会在 /tmp 里堆积垃圾目录；
#   ③ 轮次是串行的（t490_round.sh 起手就拒绝残留 QEMU 进程），不存在并发覆盖。
STAGE="${TMPDIR:-/tmp}/xk6-pages-stage"
mkdir -p "$STAGE" || exit 1

for f in $PAGE_FILES; do
    src="$PAGE_DIR/$f"
    [ -s "$src" ] || { echo "!! 页面缺失或为空: $src"; exit 1; }
    cr=$(tr -cd '\r' < "$src" | wc -c)
    [ "$cr" = "0" ] || echo "!! 注意: $f 含 $cr 个 CR 字节，已归一化为 LF"
    tr -d '\r' < "$src" > "$STAGE/$f" || exit 1
done

# ---- 3. 写入镜像 -----------------------------------------------------------
debugfs -w -R "mkdir $DEST_DIR" "$IMG" >/dev/null 2>&1
for f in $PAGE_FILES; do
    debugfs -w -R "rm $DEST_DIR/$f" "$IMG" >/dev/null 2>&1
    debugfs -w -R "write $STAGE/$f $DEST_DIR/$f" "$IMG" >/dev/null \
        || { echo "!! 注入失败: $DEST_DIR/$f"; exit 1; }
    debugfs -w -R "set_inode_field $DEST_DIR/$f mode 0100644" "$IMG" >/dev/null
done

# 兼容副本：早期 autorun（autorun_v5.sh 及更早的临时脚本）从 /root/index.html 启动。
# 语义固定为「内容 = 本轮入口页」，这样老脚本拿到的仍是"本轮想测的那个页面"。
debugfs -w -R "mkdir /root" "$IMG" >/dev/null 2>&1
debugfs -w -R "rm /root/index.html" "$IMG" >/dev/null 2>&1
debugfs -w -R "write $STAGE/$ENTRY /root/index.html" "$IMG" >/dev/null
debugfs -w -R "set_inode_field /root/index.html mode 0100644" "$IMG" >/dev/null

# ---- 4. 读回自证 -----------------------------------------------------------
echo "PAGE_MANIFEST dir=$DEST_DIR entry=$ENTRY page_dir=$PAGE_DIR files=$PAGE_FILES"
RC=0
for f in $PAGE_FILES; do
    stat_line=$(debugfs -R "stat $DEST_DIR/$f" "$IMG" 2>/dev/null \
        | grep -E "Mode:|Size:" | tr -d '\n' | tr -s ' ')
    sha=$(sha256sum "$STAGE/$f" | cut -d' ' -f1)
    echo "PAGE_INJECT $f $stat_line sha256=${sha:0:16}"

    rb="$STAGE/rb_$f"
    if debugfs -R "dump $DEST_DIR/$f $rb" "$IMG" >/dev/null 2>&1 && cmp -s "$STAGE/$f" "$rb"; then
        echo "PAGE_VERIFY $f OK（读回与源文件逐字节一致）"
    else
        echo "PAGE_VERIFY $f FAIL（读回比对不一致，镜像不可用）"
        RC=1
    fi
done

# 入口页在镜像里必须真实存在，否则会话会启动到一个不存在的 URL 上
if debugfs -R "stat $DEST_DIR/$ENTRY" "$IMG" >/dev/null 2>&1; then
    echo "PAGE_VERIFY entry_exists OK（$DEST_DIR/$ENTRY）"
else
    echo "PAGE_VERIFY entry_exists FAIL（$DEST_DIR/$ENTRY 不存在）"
    RC=1
fi

[ "$RC" = "0" ] && echo "PAGE_SET_OK" || echo "PAGE_SET_FAIL"
exit "$RC"
