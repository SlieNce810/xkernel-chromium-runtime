#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Temporarily instrument kernel KOBJECT_UEVENT subscriber delivery."""
from __future__ import annotations

from pathlib import Path

path = Path.home() / "x-kernel/net/knet/src/netlink/socket.rs"
text = path.read_text(encoding="utf-8")

old_bind = """        if addr.groups != 0 {
            subs.push(Arc::downgrade(&self.inner));
        }
"""
new_bind = """        log::warn!(
            "uevent subscriber bind pid={} groups={}",
            addr.pid,
            addr.groups,
        );
        if addr.groups != 0 {
            subs.push(Arc::downgrade(&self.inner));
        }
"""
if new_bind in text:
    print("[skip] uevent subscriber bind diagnostic already applied")
elif text.count(old_bind) == 1:
    text = text.replace(old_bind, new_bind, 1)
    print("[ok] instrumented KOBJECT_UEVENT bind groups")
else:
    raise SystemExit("[FATAL] expected one KOBJECT_UEVENT subscription anchor")

old_pub = """pub fn publish_kobject_uevent(group: u32, payload: &[u8]) {
    let seqnum = UEVENT_SEQNUM.fetch_add(1, Ordering::Relaxed) + 1;
    let mut payload_with_seqnum = Vec::with_capacity(payload.len() + 32);
    payload_with_seqnum.extend_from_slice(payload);
    payload_with_seqnum.extend_from_slice(format!("SEQNUM={seqnum}\\0").as_bytes());

    let mut subs = UEVENT_SUBSCRIBERS.lock();
    subs.retain(|weak| {
        let Some(inner) = weak.upgrade() else {
            return false;
        };
        let Some(addr) = *inner.local_addr.read() else {
            return false;
        };
        if addr.groups & group != 0
            && inner.rx_queue.lock().push_back(NetlinkPacket {
                from: NetlinkAddr {
                    pid: 0,
                    groups: group,
                },
                data: payload_with_seqnum.clone(),
            })
        {
            inner.poll_rx.wake();
        }
        true
    });
}
"""
new_pub = """pub fn publish_kobject_uevent(group: u32, payload: &[u8]) {
    let seqnum = UEVENT_SEQNUM.fetch_add(1, Ordering::Relaxed) + 1;
    let mut payload_with_seqnum = Vec::with_capacity(payload.len() + 32);
    payload_with_seqnum.extend_from_slice(payload);
    payload_with_seqnum.extend_from_slice(format!("SEQNUM={seqnum}\\0").as_bytes());

    let mut notified = 0usize;
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
}
"""
if new_pub in text:
    print("[skip] KOBJECT_UEVENT publish diagnostic already applied")
elif text.count(old_pub) == 1:
    path.write_text(text.replace(old_pub, new_pub, 1), encoding="utf-8")
    print("[ok] instrumented KOBJECT_UEVENT publish delivery counts")
else:
    raise SystemExit("[FATAL] expected one KOBJECT_UEVENT publish function")

if new_bind in text and new_pub in text:
    path.write_text(text, encoding="utf-8")

print("[done] diagnostic build will report udev netlink group subscriptions and delivery")
