#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_round_assert_prop_logs.py — 把本轮新增的 guest 日志登记进 round_assert.sh 的回收清单。

为什么需要这个补丁
------------------
round_assert.sh 的「③ 回收 guest 持久日志」小节用**硬编码的额外文件清单**调用
pull_guest_logs.sh（见该节注释：清单外的文件会被 dump 成 0 字节并被误判成"无日志"）。
本轮（属性面 uapi 探针轮）新增两个 guest 侧日志：

    /root/prop.log   autorun_prop.sh 的全量日志（含 [PROP]/[CHAIN]/[PROPSUM]/[NETSUM] 判定行）
    /root/net.log    guest 网络体检明细（决定 Weston 是"联网 apk 装"还是"离线注入装"）

不登记 → 探针结论只存在于 console.log（可读但难机器判读），且"日志完整"这一评分要求
缺一块。登记成本一行，故用本补丁显式完成，并把写入做成幂等（重复执行安全）。

用法（在 T490 上）：python3 patch_round_assert_prop_logs.py
"""
import sys
import os

TARGET = os.path.expanduser("~/xk6/scripts/t490/round_assert.sh")
ANCHOR = "/root/jwm.log \\\n"                      # 现有清单最后一项
ADDITION = "/root/jwm.log /root/prop.log /root/net.log \\\n"
NEW_ITEMS = ["/root/prop.log", "/root/net.log"]


def main() -> int:
    if not os.path.isfile(TARGET):
        print("!! 目标文件不存在: %s" % TARGET)
        return 1
    with open(TARGET, encoding="utf-8") as f:
        s = f.read()

    if all(item in s for item in NEW_ITEMS):
        print("already patched: %s" % TARGET)
        return 0

    if ANCHOR not in s:
        print("!! 锚点未找到（round_assert.sh 结构已变？）: %r" % ANCHOR)
        return 1

    backup = TARGET + ".bak-prop"
    if not os.path.exists(backup):
        with open(backup, "w", encoding="utf-8") as f:
            f.write(s)
    s = s.replace(ANCHOR, ADDITION, 1)
    with open(TARGET, "w", encoding="utf-8") as f:
        f.write(s)
    print("patched: %s" % TARGET)
    print("  backup: %s" % backup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
