#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Point sysfs character-device links to their physical device paths."""
from __future__ import annotations

from pathlib import Path

path = Path.home() / "x-kernel/fs/boot/src/lib.rs"
text = path.read_text(encoding="utf-8")
old = '            let event_dev_target = format!("../../class/input/{}", input.event_name);\n'
new = '            let event_dev_target = format!("../../{event_relative}");\n'
if new in text:
    print("[skip] /sys/dev/char already targets the physical input path")
elif text.count(old) == 1:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("[ok] /sys/dev/char/<major>:<minor> now targets /sys/devices/.../eventN")
else:
    raise SystemExit("[FATAL] expected one input /sys/dev/char target anchor")
