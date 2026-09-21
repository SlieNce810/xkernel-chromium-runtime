# Chromium on x-kernel：推进记录与剩余阻塞（2026-09-21）

> 编制：小格（赛题六 · 图形 / 浏览器链路）
> 上游：`https://gitee.com/openkylin/x-kernel.git` · 平台：T490 原生 Ubuntu 26.04 · QEMU 10.2.1 · **纯 TCG**
> 前置：G4（unix stream SCM_RIGHTS）已修 → 见 `report/09-兼容性缺口G4-unix-stream-SCM_RIGHTS.md`
> 证据目录：`evidence/2026-09-21_t490-{p1-fdpass,install,chromium,chrome2,chrome3,chrome4}/`

---

## 1. 一句话结论

**图形链路已完全打通（真实桌面 + compositor 稳定）；Chromium 已经能起来并创建出窗口，
但页面渲染卡在「utility/renderer 子进程在本内核上无法存活」——这是一个新定位到的内核兼容性缺口。**

---

## 2. 本轮达成

| 里程碑 | 状态 | 证据 |
|---|---|---|
| Weston 桌面真实渲染 | ✅ | `evidence/2026-09-21_t490-p1-fdpass/screenshots/shot-01.png`（面板 + 时钟 05:55→05:59 走了 4 分钟） |
| weston-desktop-shell 不再崩 | ✅ | 进程常驻；`create_pool` / `Quitting` 消失 |
| 字体与 Chromium 装齐（**真实实体**） | ✅ | `chromium` 249,957,096 字节；`fc-list` 75 个字体；`chromium --version` → `Chromium 149.0.7827.53 Alpine Linux` |
| **Chromium 创建出窗口** | ✅ | `evidence/2026-09-21_t490-chrome3/screenshots/shot-03.png`：屏幕中央出现标题为 **"Chromium"** 的窗口，Weston 面板时钟 07:22 AM |
| Chromium 进程稳定 | ✅ | browser PID 常驻 ≥180s，`FATAL` 行 = 0 |
| **页面渲染** | ❌ | 窗口内容为纯黑；窗口标题仍是 "Chromium"（未变成页面标题）→ **renderer 未启动** |

截图 `shot-03.png` 的画面结构：Weston 顶部面板（时钟 `Mon Sep 21, 07:22 AM`）+ 中央 Chromium 窗口
（白色标题栏 "Chromium" + 黑色内容区）+ 壁纸背景。

---

## 3. 剩余阻塞：精确诊断

### 3.1 第一层（已解）：GPU 子进程起不来

默认参数下 Chromium **自杀**：

```
ERROR:content/browser/gpu/gpu_process_host.cc:999] GPU process launch failed: error_code=1002
WARNING:...gpu_process_host.cc:1447] The GPU process has crashed 1 time(s) → 2 → 3
FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:418] GPU process isn't usable. Goodbye.
```
退出码 **rc=191**。

> **关键认知**：`--disable-gpu` **不阻止** GPU 进程存在 —— Chromium 149 仍需它做显示合成。
> 网上"加 --disable-gpu 就能在无 GPU 环境跑"的说法对本版本不成立。

**解法（已验证有效）**：加 `--in-process-gpu` 把 GPU 并进 browser 进程 → browser 存活、窗口出现。

### 3.2 第二层（当前阻塞）：utility / renderer 子进程全部活不下来

加 `--in-process-gpu` 后，日志进入稳定循环（每 ~5 秒一次），持续 ≥180 s：

```
ERROR:content/browser/network_service_instance_impl.cc:722]
    Network service crashed or was terminated, restarting service.
prctl(PR_SET_NO_NEW_PRIVS) failed
[mutex.cc : 956] RAW: pthread_getschedparam failed: 3        ← ESRCH
```
- **renderer 进程从未出现**（`pgrep -f type=renderer` 全程为空）→ 页面从未被解析/绘制 → 黑窗。
- 同时可见的相关错误：
  - `base/files/file_path_watcher_inotify.cc:338] inotify_init() failed: Function not implemented (38)`（ENOSYS）
  - `net/base/address_tracker_linux.cc:243] Could not bind NETLINK socket: Not supported (95)`（EOPNOTSUPP）
  - `content/browser/browser_main_loop.cc:274] Gdk: gdk_seat_get_keyboard: assertion 'GDK_IS_SEAT (seat)' failed`
  - `chrome_crashpad ... missing credentials`
  - `ui/ozone/.../drm_render_node_path_finder.cc:45] drmGetDevices2() has not found any devices`（已知 G5，非阻塞）
  - 大量 `dbus` 连接失败（无 dbus daemon，非阻塞）

**尝试过的降级组合**：

| 组合 | 结果 |
|---|---|
| 默认 + `--disable-gpu` | rc=191，75s，GPU FATAL |
| `--single-process --no-zygote --in-process-gpu` | **rc=191，35s**（149 上 `--single-process` 不可用） |
| **`--in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox`** | **存活 ≥180s，窗口出现，但 renderer 缺失** |

**结论**：本内核上 Chromium 的**子进程（utility / renderer）无法存活**，
表现是"spawn 后立刻死 + `PR_SET_NO_NEW_PRIVS` 失败 + `pthread_getschedparam` ESRCH"。
这已不是"参数没配对"的问题，而是**内核侧的进程/线程/调度接口缺口**。

### 3.3 待验证的修复方向（按性价比）

1. **`pthread_getschedparam` / `sched_getparam` 返回值** —— 日志里 `mutex.cc RAW: pthread_getschedparam failed: 3 (ESRCH)`。
   若内核对线程的 `sched_getparam` 返回 ESRCH，Chromium 的 `base::Lock` 会退化甚至异常。
   **建议先在 x-kernel 里补 `sched_getparam`/`sched_getscheduler` 的正确实现**（很可能就是子进程起不来的直接原因）。
2. **`inotify_init` 返回 ENOSYS → 应为 ENOSYS 还是实现** —— 已知缺口；Chromium 已有 fallback，非致命，但会拖慢。
3. **netlink socket 绑定 EOPNOTSUPP** —— 网络服务崩溃的直接原因（`address_tracker_linux`）。
   若补上 netlink（至少 `NETLINK_ROUTE` 的最小只读实现），network service 循环即可停止。
4. **`landlock_create_ruleset` 未实现**（`ksyscall::dispatch:855 Unimplemented syscall`）—— 当前非致命，
   但 Chromium 会不断尝试，建议至少返回 `ENOSYS` 而非 "Unimplemented" 告警。
5. **`unshare`/`setns`** —— 已有记录；`--no-sandbox` 下不需要。

---

## 4. 本轮新发现的缺口（追加登记）

| # | 缺口 | 现象 / 证据 | 影响 |
|---|---|---|---|
| **G6** | **`virtio-mouse-pci` 在 guest 内没有生成 evdev 节点** | `evprobe`：只有 `/dev/input/event0`(13:1) = "QEMU Virtio Keyboard"；`EVMAP pointer=c13:-1` | 决赛「鼠标点击跳转」拿不到；键盘回显前提已具备 |
| **G7** | guest 侧 udev 伪造次设备号**写反** | `guest-bootstrap.sh` 写 `c13:1=ID_INPUT_MOUSE`，实测 13:1 是**键盘** | 静默无输入；已在本轮修复 |
| **G8** | guest 网络不可达 | `eth0=10.0.2.15`、DNS `10.0.2.3` 均正常，但取包 0 字节 | 不能在 guest 内 apk；叠加 G9 |
| **G9** | netlink socket 绑定 `EOPNOTSUPP(95)` | Chromium `address_tracker_linux.cc:243`；network service 崩溃循环 | **浏览器功能阻塞项之一** |
| **G10** | `pthread_getschedparam` 返回 `ESRCH(3)` | Chromium `[mutex.cc : 956] RAW:` | **疑为子进程起不来的根因** |
| **G11** | `prctl(PR_SET_NO_NEW_PRIVS)` 失败 | 每次子进程 spawn 后必现 | 与 G10 同源 |
| **G12** | `inotify_init()` → `ENOSYS(38)` | Chromium `file_path_watcher_inotify.cc:338` | 有 fallback，非致命 |
| **G13** | `landlock_create_ruleset` 未实现 | `ksyscall::dispatch:855 Unimplemented syscall` | Chromium 反复尝试；建议返回 ENOSYS |

> G5（`drmGetDevices2` 返回 0）仍为非阻塞，已在上游报告过。

---

## 5. ⚠️ 镜像质量问题（影响所有后续轮次）

**`images/p0-drmversion-fixed.img` 里"apk 预装"那批文件全是 0 字节空壳**：

```
/usr/share/fonts/{noto,opensans}/*.tt[fc]   Size 0  Blockcount 0
/usr/lib/chromium/chromium                  Size 0  Blockcount 0
/etc/fonts/fonts.conf                       Size 0   ← Fontconfig "line 1: no element found" 的根因
/lib/apk/db/installed                       Size 0   ← apk 认为"什么都没装"
对照 /usr/bin/weston 67240 / Blockcount 136（真实）
```

`debugfs -R "dump"` 出来也是 0 字节 → **真真空**，目录/inode/权限都在、只有内容不在。
→ **凡"apk 预装"路径进来的文件都不可信，用前必须 `debugfs -R "stat"` 查 Size/Blockcount。**

**新基座镜像（本轮产出）**：
```
~/x-kernel/images/pkg-installed.img   4 GB
sha256 56302b8f4d1c56d99f2ba6e84998448ed5caa09093ee3663fbc07c8741e091de
```
含 weston 全家桶 + fontconfig + OpenSans/Noto/NotoCJK + Chromium 149 + 2953 个文件 + **342 个符号链接**（全部真实）。
后续轮次以它为 `BASE_IMG`，可跳过 387 MB 注入与解包。

---

## 6. 已建立的可复用资产（scripts/t490/）

| 文件 | 作用 |
|---|---|
| **`t490_round.sh`** | **通用单轮编排**：`t490_round.sh <tag> <dur> <ival> <autorun> [probe.c...]`；支持 `BASE_IMG` / `PKG_TARBALL` / `PAGE_HTML` 注入。取代 v7..v16 的手写注入脚本 |
| `t490_build_pkgs.sh` | 宿主侧跨架构建包：`apk.static --usermode --arch aarch64` → 打成**单个** tar.gz |
| `autorun_install.sh` | guest 内解包 + 校验 + udev 伪造（c13:1=键盘）+ weston（**钉死 `--socket=wayland-0`**）+ Chromium 两次尝试 + watcher |
| `autorun_p1.sh` | G4 验收专用单路线总控 |
| `fdprobe.c` | SCM_RIGHTS 跨进程 fd 传递探针（T1–T4，输出 `[RESULT] T1_fd_count=`） |
| `evprobe.c` | evdev 归类探针（EVIOCGNAME/EVIOCGID/EVIOCGBIT → KEYBOARD/MOUSE/…） |
| `p1_stream_ancillary.py` | G4 补丁应用器（幂等、不盲改） |

### 关键工程决策：tar 注入而非逐文件注入
`debugfs` 的 `write` 只能写普通文件；本轮需要注入 **342 个符号链接** + 2953 个文件。
改为「宿主建树 → `tar -czf` → 注入**一个** tar → guest 内 `tar -x`」，由 tar 保证
symlink / mode / hardlink 全部保真。

---

## 7. 关键坑位清单（本轮踩到的，务必记住）

| # | 坑 | 对策 |
|---|---|---|
| 1 | `apk search -q -x` 在索引签名不受信时**静默 rc=1 无输出** → 所有包被判"不存在"（本轮把 chromium 整包漏掉一次） | 直接解析 `APKINDEX.tar.gz`：`tar -xzOf … APKINDEX \| grep '^P:'` |
| 2 | 小文件测速会骗人。500 KB 的 APKINDEX 测得 aliyun 932 KB/s 最快，但 `apk.static` 在 aliyun 上**大包会卡死**（26 分钟 0 进度、CPU 0%、1 条 ESTAB 空转） | 改用 **ustc**（chromium 大包实测 3.5 MB/s）+ `nohup` 直写日志 + `-v`；**别把 apk 输出管道给 `tail`**（会缓冲到结束） |
| 3 | **weston 的 socket 名不是 `wayland-0`** | weston `wl_display_add_socket_auto()` 在本内核上跳过 0 直接用 `wayland-1`（疑与 flock 语义不完整有关）；必须显式 `--socket=wayland-0`，客户端侧也要用发现到的实际名字 |
| 4 | guest 的 `/tmp` 是 **tmpfs（内存）**，QEMU 一停日志就没了 | Chromium 日志必须写 `/root/`；上一轮就是写 `/tmp` 且当时还没写入，结果什么都没抓到 |
| 5 | `--disable-gpu` ≠ 没有 GPU 进程 | 必须加 `--in-process-gpu` |
| 6 | `pkill -f <pattern>` 会匹配到承载它的 ssh 远端 shell 自己 → 自杀（无输出 + exit 127） | 用字符类规避：`pkill -f "qemu-syste[m]"` |
| 7 | 非交互 ssh 下 `rustc` 落到 `/usr/bin/rustc`(1.93.1) | `export PATH="$HOME/.cargo/bin:$PATH"` → 1.95.0 |

---

## 8. 下一步（按优先级）

1. **补 `sched_getparam`/`pthread_getschedparam` 相关实现** → 验证 renderer 能否起来。
   这是当前唯一阻塞「浏览器功能 20 分」的点，且补丁量小、可上游。
2. **补 netlink（至少 `NETLINK_ROUTE` 最小只读）** → 消除 network service 崩溃循环（且顺带可能修好 G8 guest 网络）。
3. **`virtio-mouse` 生成 evdev 节点**（G6）→ 决赛鼠标 4 分。
4. 上述任一项打通后，跑 **660 s 长稳** + 替换组委会测试页出正式证据。

---

## 9. 复现命令（T490）

```bash
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/xk6

# ① 宿主侧建包（只需一次；已产出 ~/xk6/tmp/pkgs-fetch.tar.gz 387MB）
bash ~/xk6/scripts/t490/t490_build_pkgs.sh

# ② 装包轮（只需一次；已产出 images/pkg-installed.img）
PKG_TARBALL=$HOME/xk6/tmp/pkgs-fetch.tar.gz \
PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh install 1200 120 autorun_install.sh

# ③ 后续轮次（直接用已装包的基座镜像）
BASE_IMG=$HOME/x-kernel/images/pkg-installed.img \
PAGE_HTML=$HOME/xk6/scripts/testpage/local-check.html \
  bash ~/xk6/scripts/t490/t490_round.sh chrome 900 150 autorun_install.sh

# ④ 看结果
D=~/xk6/evidence/$(date +%Y-%m-%d)_t490-chrome
tr -d '\r' < $D/console.log | grep -nE "尝试 |仍在运行|已退出|browser=|renderer=|FATAL 行"
debugfs -R "cat /root/chromium.log" ~/x-kernel/disk.img | tr -d '\r' | tail -60
```
