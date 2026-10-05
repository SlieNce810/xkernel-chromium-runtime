#!/bin/sh
# autorun_plane.sh —— plane 属性面探针轮（Weston "Failed to find primary plane" 根因定位）
#
# 用途：一轮内把 Weston 14 `drm_plane_create()` 的全部候选失败点变成可判读事实：
#   - plane 是否被内核枚举（GETPLANERESOURCES）
#   - plane 的 crtc_id / possible_crtcs（Weston 的 drm_plane_is_available 判据）
#   - 逐属性名解析（Weston 就是靠 name=='type' 拿到 plane 类型；拿不到则 plane 创建失败）
#   - IN_FORMATS blob 的头部与字段布局（modifiers 路径的输入）
#   - CAP(ADDFB2_MODIFIERS)（决定 Weston 走 modifiers 还是 fallback）
#
# 输出：/root/prop.log（已登记进 round_assert 回收清单）+ 同步到串口
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/prop.log
: > "$LOG"

log() {
    echo "[plane] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"

if [ -x /drmplaneprobe ]; then
    /drmplaneprobe > /root/plane.out 2>&1 &
    pp=$!
    j=0
    while [ "$j" -lt 90 ]; do
        [ -d /proc/$pp ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$pp ]; then
        log "!! 探针超过 ${j}s 未返回 → HUNG, kill -9"
        kill -9 "$pp" 2>/dev/null
        echo "HUNG" >> "$LOG"
    else
        wait "$pp"
        log "探针 rc=$? 输出 $(wc -c < /root/plane.out 2>/dev/null) 字节（等待 ${j}s）"
    fi
    cat /root/plane.out >> "$LOG"
    cat /root/plane.out > /dev/console 2>&1
    log "----- 判定行 -----"
    grep -aE '^\[CAP\]|^\[PRES\]|^\[PLANE\]|^\[PROP\]|^\[BLOB\]|^\[PLANESUM\]' /root/plane.out \
        | tail -60 > /dev/console 2>&1
else
    log "!! /drmplaneprobe 未注入 —— 检查 t490_round.sh 的 probe 参数"
fi

log "done"

# 保持会话存活（供宿主侧周期 screendump 与收尾取证）
n=0
while [ "$n" -lt 5 ]; do
    sync
    n=$((n + 1))
    sleep 30
done
sync
sync
