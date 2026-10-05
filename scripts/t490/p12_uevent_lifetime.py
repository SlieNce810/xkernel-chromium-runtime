#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Diagnose KOBJECT_UEVENT socket weak-reference lifetime and bind state."""
from __future__ import annotations

from pathlib import Path

path = Path.home() / "x-kernel/net/knet/src/netlink/socket.rs"
text = path.read_text(encoding="utf-8")

old_bind = '''        log::warn!(
            "uevent subscriber bind pid={} groups={}",
            addr.pid,
            addr.groups,
        );
'''
new_bind = '''        log::warn!(
            "uevent subscriber bind pid={} groups={} strong_count={}",
            addr.pid,
            addr.groups,
            Arc::strong_count(&self.inner),
        );
'''
if new_bind in text:
    print("[skip] bind strong-count diagnostic already applied")
elif text.count(old_bind) == 1:
    text = text.replace(old_bind, new_bind, 1)
    print("[ok] instrumented uevent bind Arc strong count")
else:
    raise SystemExit("[FATAL] expected p11 uevent bind diagnostic")

old_pub = '''    let mut notified = 0usize;
    let mut matching = 0usize;
    let mut subs = UEVENT_SUBSCRIBERS.lock();
    subs.retain(|weak| {
        let Some(inner) = weak.upgrade() else {
            return false;
        };
        let Some(addr) = *inner.local_addr.read() else {
            return false;
        };
        if addr.groups & group != 0 {
            matching += 1;
            if inner.rx_queue.lock().push_back(NetlinkPacket {
                from: NetlinkAddr {
                    pid: 0,
                    groups: group,
                },
                data: payload_with_seqnum.clone(),
            }) {
                notified += 1;
                inner.poll_rx.wake();
            }
        }
        true
    });
    log::warn!(
        "uevent publish group={} matching_subscribers={} notified={} seqnum={}",
        group, matching, notified, seqnum,
    );
'''
new_pub = '''    let mut notified = 0usize;
    let mut matching = 0usize;
    let mut live = 0usize;
    let mut dead = 0usize;
    let mut unbound = 0usize;
    let mut group_mismatch = 0usize;
    let mut subs = UEVENT_SUBSCRIBERS.lock();
    subs.retain(|weak| {
        let Some(inner) = weak.upgrade() else {
            dead += 1;
            return false;
        };
        live += 1;
        let Some(addr) = *inner.local_addr.read() else {
            unbound += 1;
            return true;
        };
        if addr.groups & group != 0 {
            matching += 1;
            if inner.rx_queue.lock().push_back(NetlinkPacket {
                from: NetlinkAddr {
                    pid: 0,
                    groups: group,
                },
                data: payload_with_seqnum.clone(),
            }) {
                notified += 1;
                inner.poll_rx.wake();
            }
        } else {
            group_mismatch += 1;
        }
        true
    });
    log::warn!(
        "uevent publish group={} live={} dead={} unbound={} group_mismatch={} matching_subscribers={} notified={} seqnum={}",
        group, live, dead, unbound, group_mismatch, matching, notified, seqnum,
    );
'''
if new_pub in text:
    print("[skip] publish lifetime counters already applied")
elif text.count(old_pub) == 1:
    text = text.replace(old_pub, new_pub, 1)
    print("[ok] instrumented uevent publish weak-reference states")
else:
    raise SystemExit("[FATAL] expected p11 uevent publish diagnostic")

if "impl Drop for NetlinkSocket" not in text:
    marker = "impl NetlinkSocket {\n"
    drop_impl = '''impl Drop for NetlinkSocket {
    fn drop(&mut self) {
        if self.inner.protocol == NETLINK_KOBJECT_UEVENT {
            let addr = *self.inner.local_addr.read();
            log::warn!(
                "uevent socket wrapper drop strong_count={} local_addr={:?}",
                Arc::strong_count(&self.inner),
                addr,
            );
        }
    }
}

'''
    if text.count(marker) != 1:
        raise SystemExit("[FATAL] expected one NetlinkSocket impl marker")
    text = text.replace(marker, drop_impl + marker, 1)
    print("[ok] instrumented uevent socket wrapper drop")
else:
    print("[skip] wrapper-drop diagnostic already applied")

path.write_text(text, encoding="utf-8")
print("[done] next build reports expired, live, unbound, and mismatched subscribers")
