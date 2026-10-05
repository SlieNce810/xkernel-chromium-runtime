#!/bin/sh
# ============================================================================
# /etc/profile.d/99-autostart.sh — x-kernel guest 启动钩子
# 由 t490_round.sh 在每轮注入时写入（见该脚本「4a. autostart 钩子」小节）
#
# 为什么必须有这个文件
#   t490_round.sh 的编排契约是「<autorun文件名> 注入为 /root/autorun.sh
#   （guest 的 99-autostart 会调它）」。旧 WSL 镜像确实由人工注入过这个钩子，
#   但 agentos 官方 kiosk 镜像里 /etc/profile.d/ 只有：
#       20locale.sh / README / color_prompt.sh.disabled
#   没有任何东西会去执行 /root/autorun.sh —— 于是整轮会「什么都不发生」：
#   QEMU 正常起、串口正常出 shell、guest 侧零动作、framebuffer 从未被 modeset，
#   screendump 恒为 "Display output is not active."（report/25 的 X11 冒烟轮
#   就栽在这里）。这种「静默空跑」是最贵的失败，所以钩子必须随轮注入。
#
# 机制（为什么是 /etc/profile.d）
#   x-kernel 的 PID 1 是 `/bin/sh --login`（不是 BusyBox init，/etc/inittab 不生效）。
#   BusyBox ash 的 login shell 会 source /etc/profile，
#   而该镜像的 /etc/profile 结尾正是：
#       for script in /etc/profile.d/*.sh ; do . "$script" ; done
#   所以 /etc/profile.d/ 是**跨镜像通用**的自动启动挂点。
#
# 幂等性
#   `XKERNEL_AUTOSTART_DONE` 环境变量 + 一次即可的语义：autorun 只被拉起一次。
#   /etc/profile 可能被多个登录 shell 重复 source（例如手动 exec sh -l），
#   若无此守卫会出现多份 Xorg/Chromium 抢 /dev/dri/card0。
# ============================================================================

[ -n "${XKERNEL_AUTOSTART_DONE:-}" ] && return 0
export XKERNEL_AUTOSTART_DONE=1

echo "[autostart] hook fired ($(date 2>/dev/null))" > /dev/console 2>/dev/null

if [ -x /root/autorun.sh ]; then
    echo "[autostart] launching /root/autorun.sh in background" > /dev/console 2>/dev/null
    # 必须后台：autorun 里含 Xorg/Chromium 启动与等待，前台会把这个 login shell 卡死，
    # 而 run-session.py 依赖串口 shell 存活来发送命令与判定会话状态。
    # stdout/stderr 落 /tmp（tmpfs）避免与 autorun 自己的 /dev/console 双写打架。
    ( /root/autorun.sh >/tmp/autorun-boot.log 2>&1 & )
else
    echo "[autostart] !! /root/autorun.sh 不存在或不可执行 —— 本轮 guest 侧不会有任何动作" \
        > /dev/console 2>/dev/null
fi
