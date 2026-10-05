#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Trace real evdev opens and ioctls from Weston/libinput."""
from __future__ import annotations

from pathlib import Path

path = Path.home() / "x-kernel/fs/filesystems/devfs/src/nodes/event.rs"
text = path.read_text(encoding="utf-8")

old_open = '''impl DeviceFileOps for EventDev {
    fn open(&self, _inode: &VfsInode, file: &mut VfsFileBuilder) -> VfsResult<()> {
        file.stream_open();
'''
new_open = '''impl DeviceFileOps for EventDev {
    fn open(&self, _inode: &VfsInode, file: &mut VfsFileBuilder) -> VfsResult<()> {
        warn!("evdev open event node");
        file.stream_open();
'''
if new_open in text:
    print("[skip] evdev open trace already applied")
elif text.count(old_open) == 1:
    text = text.replace(old_open, new_open, 1)
    print("[ok] traced evdev open calls")
else:
    raise SystemExit("[FATAL] expected EventDev::open anchor")

old_ioctl = '''    fn ioctl(&self, _file: &VfsFile, cmd: u32, arg: usize) -> VfsResult<usize> {
        match cmd {
'''
new_ioctl = '''    fn ioctl(&self, _file: &VfsFile, cmd: u32, arg: usize) -> VfsResult<usize> {
        warn!("evdev ioctl cmd={cmd:#010x} arg={arg:#x}");
        match cmd {
'''
if new_ioctl in text:
    print("[skip] evdev ioctl trace already applied")
elif text.count(old_ioctl) == 1:
    text = text.replace(old_ioctl, new_ioctl, 1)
    print("[ok] traced evdev ioctl calls")
else:
    raise SystemExit("[FATAL] expected EventDev::ioctl anchor")

path.write_text(text, encoding="utf-8")
print("[done] next run will show the evdev open and ioctl sequence")
