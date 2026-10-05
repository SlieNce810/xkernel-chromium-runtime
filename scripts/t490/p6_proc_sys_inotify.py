#!/usr/bin/env python3
"""P6 补丁应用器：procfs 暴露 /proc/sys/fs/inotify/* 三个配额文件。

背景（2026-09-22 fullbase 轮实测，证据 evidence/2026-09-22_t490-fullbase）
--------------------------------------------------------------------------
Chromium 的 `base/files/file_path_watcher_inotify.cc` 在真正调用 inotify 之前，
会先读 `max_user_watches` 决定 watch 配额解析路径：

    [181:181:0922/023037.933628:ERROR:base/files/file_path_watcher_inotify.cc:922]
        Failed to read /proc/sys/fs/inotify/max_user_watches

同一轮 0.2 节静态探针的实测结果：

    [full]   !! /proc/sys/fs/inotify 不存在

即 x-kernel 的 procfs 只挂了 `/proc/sys/kernel/pid_max` 一项，`/proc/sys/fs/`
整棵子树缺失。Linux 上这三个文件是**普通只读配额值**，缺了就是接口缺口。

修法：在已有的 `sys` 节点下增设 `fs/inotify/{max_queued_events,
max_user_instances,max_user_watches}`，取值照 Linux 默认
（fs/inotify 的内核默认：16384 / 128 / 65536）。只读，不引入可写语义，
因此不改变任何既有行为。

不改的东西（刻意）
------------------
- **不实现 inotify 系统调用本身**。同一轮日志另有

      [141:262:...:ERROR:base/files/file_path_watcher_inotify.cc:338]
          inotify_init() failed: Function not implemented (38)

  这是真的缺功能（要新增 inotify fs 实例、watch 队列、事件投递），
  属于新功能而非 errno 修正，按要求**不夹带**在本轮的"接口存在性"修正里。
  先只把配额文件补上，让 Chromium 走到 inotify_init 这步再看 fallback 是否够用。
- 不把值写成 0：0 会被 Chromium 解释成"配额为零"，比文件缺失更糟。
"""

import sys
from pathlib import Path

ROOT = "fs/filesystems/procfs/src/basic_nodes/root.rs"

# 锚点：sys 节点里 kernel 子目录的收尾 + sys 自身的 SimpleDir::new_maker。
# 用「sys 收尾」而不是「kernel 收尾」做锚，是为了让插入点落在 sys 的直接子项，
# 与 kernel 平级 —— 正是 Linux 上 /proc/sys/kernel 与 /proc/sys/fs 的关系。
ANCHOR_OLD = """        SimpleDir::new_maker(fs.clone(), Arc::new(sys))
    });
"""

ANCHOR_NEW = """        sys.add("fs", {
            let mut sys_fs = DirMapping::new();

            sys_fs.add("inotify", {
                let mut inotify = DirMapping::new();
                // Chromium 的 file_path_watcher_inotify.cc 读 max_user_watches
                // 决定 watch 配额；缺失时报 "Failed to read
                // /proc/sys/fs/inotify/max_user_watches"，watch 功能整体降级。
                // 取值照 Linux 默认（fs/inotify 的初始值），仅只读暴露。
                inotify.add(
                    "max_queued_events",
                    SimpleFile::new_regular(fs.clone(), || Ok("16384\\n")),
                );
                inotify.add(
                    "max_user_instances",
                    SimpleFile::new_regular(fs.clone(), || Ok("128\\n")),
                );
                inotify.add(
                    "max_user_watches",
                    SimpleFile::new_regular(fs.clone(), || Ok("65536\\n")),
                );
                SimpleDir::new_maker(fs.clone(), Arc::new(inotify))
            });

            SimpleDir::new_maker(fs.clone(), Arc::new(sys_fs))
        });

        SimpleDir::new_maker(fs.clone(), Arc::new(sys))
    });
"""

applied = 0
skipped = 0


def replace_once(path: str, old: str, new: str, label: str) -> None:
    """幂等替换：已应用则跳过，锚点缺失则大声失败（不静默放过）。"""
    global applied, skipped
    p = Path(path)
    if not p.exists():
        sys.exit(f"[FATAL] {path} 不存在（请在仓库根目录运行）")
    text = p.read_text(encoding="utf-8")
    if new in text:
        print(f"[skip] 已应用：{label}")
        skipped += 1
        return
    if old not in text:
        sys.exit(f"[FATAL] 锚点缺失：{label}（{path}）—— 上游代码可能已变动，请人工核对")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[ok]   已修改：{label}")
    applied += 1


if "--revert" in sys.argv:
    replace_once(ROOT, ANCHOR_NEW, ANCHOR_OLD, "proc/sys/fs/inotify 三个配额文件")
    print(f"\n[done] 已回退 {applied} 处")
    sys.exit(0)

replace_once(ROOT, ANCHOR_OLD, ANCHOR_NEW, "proc/sys/fs/inotify 三个配额文件")

print(f"\n[done] P6 proc/sys/fs/inotify 补丁：本次实际改动 {applied} 处"
      f"（幂等，其余 {skipped} 处为已应用跳过）")
