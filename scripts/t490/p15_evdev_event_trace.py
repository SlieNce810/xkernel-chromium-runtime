#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Add a bounded evdev event trace to the existing x-kernel diagnostic build.

This is deliberately a source-level probe, not a behavior change: it logs
events returned by the already implemented ``InputDevice::read_event`` path so
the QEMU input transcript can be compared with guest consumption.
"""

from pathlib import Path


path = Path.home() / "x-kernel/fs/filesystems/devfs/src/nodes/event.rs"
source = path.read_text(encoding="utf-8")

old = '''                Ok(event) => {
                    if event.event_type == EventType::Key as u16 {
'''
new = '''                Ok(event) => {
                    warn!(
                        "evdev event type={} code={} value={}",
                        event.event_type,
                        event.code,
                        event.value
                    );
                    if event.event_type == EventType::Key as u16 {
'''
if '"evdev event type=' in source:
    print("[skip] evdev event trace already present")
elif source.count(old) == 1:
    path.write_text(source.replace(old, new, 1), encoding="utf-8")
    print("[ok] added evdev event trace")
else:
    raise SystemExit("[FATAL] expected EventDev::has_event anchor not found")
