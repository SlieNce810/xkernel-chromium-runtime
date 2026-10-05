#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_round_assert_logs.py — 把 guest 侧持久日志登记进 round_assert.sh 的回收清单（幂等）。

背景
----
round_assert.sh 的「③ 回收 guest 持久日志」用**硬编码的文件清单**调用
pull_guest_logs.sh；清单外的文件会 dump 成 0 字节，被误判成"本轮无日志"。
（该节注释里已写明这个坑的两次历史踩坑：autorun_v3 的 full.log、autorun_x11 的 xorg.log。）

本脚本把清单**一次性补齐**到当前轮次需要的全集，并把写入做成幂等：
重复执行安全，清单已含某个文件时不会重复添加。

当前需要的清单
--------------
    /root/prop.log           属性面探针轮全量日志（[PROP]/[CHAIN]/[PROPSUM]/[NETSUM]）
    /root/net.log            guest 网络体检明细
    /root/weston-round.log   Weston 轮主日志（装包/启动/周期记录）
    /root/weston.log         weston 自身 --log 输出
    /root/seatd.log          seatd 输出
    /root/weston-install.log apk 装包输出
    /root/simple-shm.log     weston-simple-shm 客户端输出

用法（在 T490 上）：python3 patch_round_assert_logs.py
"""
import os
import re
import sys

TARGET = os.path.expanduser("~/xk6/scripts/t490/round_assert.sh")

# 需要登记的全部 guest 日志（顺序即写入顺序）
EXTRA_LOGS = [
    "/root/prop.log",
    "/root/net.log",
    "/root/weston-round.log",
    "/root/weston.log",
    "/root/seatd.log",
    "/root/weston-install.log",
    "/root/simple-shm.log",
]


def main() -> int:
    if not os.path.isfile(TARGET):
        print("!! 目标文件不存在: %s" % TARGET)
        return 1

    with open(TARGET, encoding="utf-8") as f:
        s = f.read()

    # 定位现有清单里那一行（以 /root/jwm.log 为锚，行尾是续行反斜杠）
    pat = re.compile(r"^([ \t]*)(/root/jwm\.log[^\n]*?)\s*\\$", re.M)
    m = pat.search(s)
    if not m:
        print("!! 未找到 /root/jwm.log 续行（round_assert.sh 结构已变？）")
        return 1

    indent, current = m.group(1), m.group(2)
    have = set(current.split())
    missing = [p for p in EXTRA_LOGS if p not in have]

    if not missing:
        print("already patched: 清单已含全部额外日志")
        return 0

    new_list = " ".join([current] + missing)
    new_line = "%s%s \\" % (indent, new_list)

    backup = TARGET + ".bak-logs"
    if not os.path.exists(backup):
        with open(backup, "w", encoding="utf-8") as f:
            f.write(s)

    s = s[:m.start()] + new_line + s[m.end():]
    with open(TARGET, "w", encoding="utf-8") as f:
        f.write(s)

    print("patched: %s" % TARGET)
    print("  added:   %s" % " ".join(missing))
    print("  backup:  %s" % backup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
