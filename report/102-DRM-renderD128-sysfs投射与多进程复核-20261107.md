# DRM renderD128 sysfs 投射与多进程复核（2026-11-07）

## 1. 修复内容

在 `fs/boot/src/lib.rs::create_sys_drm_entries` 中补齐 render node 的 sysfs 投射：

```text
/sys/class/drm/renderD128/dev
/sys/class/drm/renderD128/uevent
/sys/class/drm/renderD128/device
/sys/class/drm/renderD128/subsystem
/sys/dev/char/226:128 -> /sys/class/drm/renderD128
/sys/devices/simpledrm/drm/renderD128 -> /sys/class/drm/renderD128
```

此前 `/dev/dri/renderD128` 虽然存在，但 `/sys/class/drm` 只有 `card0/dev`，
Chromium Ozone 的 `GetDrmRenderNodePath()` 无法通过 sysfs 找到 render node，日志为：

```text
Failed to find drm render node path.
Failed to initialize drm render node handle.
```

补丁 SHA-256：

```text
ddfd389d6aa632e08610afef07f357e3c240d6b39578d85299ffd4d625653d48
```

当前包含 Unix socket 修复和 renderD128 投射的内核构建指纹：

```text
kernel_bin_sha256=ebf8cdb28f37b63f9138a3cd6c6ae12fb78d614c7e8f7e3312a7e7274acc44c9
```

## 2. A/B 结果

证据目录：
`evidence/2026-11-07_t490-mp-render-sysfs-fix-b73-20261107-r1/`

本轮确认：

```text
DRM_SYSFS=/sys/class/drm/card0/dev
/sys/class/drm/renderD128/dev
/sys/class/drm/renderD128/device
/sys/class/drm/renderD128/subsystem
/sys/class/drm/renderD128/uevent
```

Chromium 的 render node 警告不再出现，说明 sysfs 投射已被用户态正确发现。

但默认多进程页面仍未通过：

```text
GATE page_fail=1
strict_fail=4
warmup=4
heartbeats=0/3
```

因此 renderD128 sysfs 是一个真实的图形环境兼容性缺陷，已修复，但不是当前
多进程 HTML 白屏的充分条件。

## 3. 当前边界

此时已经同时具备：

- Weston DRM/Pixman 初始化；
- card0 和 renderD128 设备节点；
- card0/renderD128 sysfs 投射；
- Unix stream/seqpacket 大消息、EOF、MSG_PEEK 语义；
- renderer 多进程创建和持续 socket 收发；
- 单进程完整 HTML/CSS/JS 页面渲染。

默认多进程仍白屏，剩余问题继续集中在 browser 导航提交、renderer/viz 资源生产、
Wayland configure/ack 和实际 page buffer 内容，而不是基础 DRM 节点或 Unix socket
创建失败。
