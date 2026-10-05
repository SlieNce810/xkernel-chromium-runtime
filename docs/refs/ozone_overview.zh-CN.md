# Ozone Overview

> Ozone 概览

**译者说明**：本文件为逐段对照译本。每段英文原文均保留原样（含原始换行、链接、代码块），紧随其后的引用块（`>`）为对应的中文译文；代码块为命令与配置内容，按原文照录、不作翻译。专有名词（Ozone、Aura、Mojo、Wayland、Mir、Mesa、GBM、DRM/KMS、Weston、Mutter、Igalia、Fuchsia、Ash、Flatland、libcaca 等）及各接口/类/宏/构建参数名（如 `PlatformWindow`、`ozone_extra.gni`、`--ozone-platform`）保留英文原样，以与上游代码保持一致。

原文地址：<https://chromium.googlesource.com/chromium/src/+/main/docs/ozone_overview.md>

---

Ozone is a platform abstraction layer beneath the Aura window system that is
used for low level input and graphics. Once complete, the abstraction will
support underlying systems ranging from embedded SoC targets to new
X11-alternative window systems on Linux such as Wayland or Mir to bring up Aura
Chromium by providing an implementation of the platform interface.

> Ozone 是位于 Aura 窗口系统之下的一个平台抽象层，用于低层输入与图形。一旦完成，该抽象层将支持从嵌入式 SoC 目标平台，到 Linux 上诸如 Wayland 或 Mir 这类可替代 X11 的新型窗口系统在内的各类底层系统，通过提供平台接口的一种实现来拉起 Aura Chromium。

> Note: There are 2 buildflags which target platforms who use OZONE.
> They are slightly different from each other:
> * IS_OZONE: Targets Linux, ChromeOS, and Fuchsia.
> * SUPPORTS_OZONE_WAYLAND: Targets only Linux systems supporting the Wayland
    window manager. Does not include ChromeOS or Fuchsia. Note that this flag
    only indicates that the build supports wayland, it does not mean that the
    build is running with the Wayland window manager.

> 注意：有两个针对使用 OZONE 的平台的构建标志（buildflag），二者略有不同：
> * IS_OZONE：面向 Linux、ChromeOS 和 Fuchsia。
> * SUPPORTS_OZONE_WAYLAND：仅面向支持 Wayland 窗口管理器的 Linux 系统。不包含 ChromeOS 或 Fuchsia。注意，该标志仅表示构建产物支持 Wayland，并不意味着该构建产物正运行在 Wayland 窗口管理器之上。

## Guiding Principles

> 指导原则

Our goal is to enable chromium to be used in a wide variety of projects by
making porting to new platforms easy. To support this goal, ozone follows the
following principles:

> 我们的目标是让 Chromium 能够被用于各种各样的项目，办法是使移植到新平台变得容易。为支撑这一目标，Ozone 遵循以下原则：

1. **Interfaces, not ifdefs**. Differences between platforms are handled by
   calling a platform-supplied object through an interface instead of using
   conditional compilation. Platform internals remain encapsulated, and the
   public interface acts as a firewall between the platform-neutral upper
   layers (aura, blink, content, etc) and the platform-specific lower layers.
   The platform layer is relatively centralized to minimize the number of
   places ports need to add code.

> 1. **用接口，而非 ifdef**。平台之间的差异，通过接口调用平台所提供的对象来处理，而不是使用条件编译。平台内部实现保持封装，公共接口充当平台无关的上层（aura、blink、content 等）与平台相关的下层之间的隔离屏障。平台层相对集中，以尽量减少移植方需要添加代码的位置数量。

2. **Flexible interfaces**. The platform interfaces should encapsulate just what
   chrome needs from the platform, with minimal constraints on the platform's
   implementation as well as minimal constraints on usage from upper layers. An
   overly prescriptive interface is less useful for porting because fewer ports
   will be able to use it unmodified. Another way of stating is that the
   platform layer should provide mechanism, not policy.

> 2. **灵活的接口**。平台接口应只封装 Chrome 需要平台提供的东西，既对平台的实现施加最小的约束，也对上层的使用施加最小的约束。一个规定得过于死板的接口对移植而言用处更小，因为能够不加修改就使用它的移植会更少。换一种说法：平台层应提供机制，而非策略。

3. **Runtime binding of platforms**. Avoiding conditional compilation in the
   upper layers allows us to build multiple platforms into one binary and bind
   them at runtime. We allow this and provide a command-line flag to select a
   platform (`--ozone-platform`) if multiple are enabled. Each platform has a
   unique build define (e.g. `ozone_platform_foo`) that can be turned on or off
   independently.

> 3. **平台的运行时绑定**。在上层避免条件编译，使我们能够把多个平台构建进同一个二进制文件，并在运行时绑定它们。我们允许这样做，并在启用了多个平台时提供一个命令行标志来选择平台（`--ozone-platform`）。每个平台都有一个唯一的构建定义（build define，例如 `ozone_platform_foo`），可以独立开启或关闭。

4. **Easy out-of-tree platforms**. Most ports begin as forks. Some of them
   later merge their code upstream, others will have an extended life out of
   tree. This is OK, and we should make this process easy to encourage ports,
   and to encourage frequent gardening of chromium changes into the downstream
   project. If gardening an out-of-tree port is hard, then those projects will
   simply ship outdated and potentially insecure chromium-derived code to users.
   One way we support these projects is by providing a way to inject additional
   platforms into the build by only patching one `ozone_extra.gni` file.

> 4. **易于实现树外（out-of-tree）平台**。大多数移植最初都是分叉（fork）。其中一些后来把代码合并回上游，另一些则会在树外长期存在。这没有问题，我们应当让这一过程变得容易，以鼓励移植，并鼓励把 Chromium 的变更频繁地"园艺"（gardening，指持续把上游变更同步、回植到下游项目）到下游项目中。如果对一个树外移植项目做园艺维护很困难，那么这些项目就只能向用户交付过时的、且可能存在安全隐患的基于 Chromium 的代码。我们支持这些项目的一种方式，就是提供一条途径：只需修改一个 `ozone_extra.gni` 文件，便能向构建中注入额外的平台。

## Ozone Platform Interface

> Ozone 平台接口

Ozone moves platform-specific code behind the following interfaces:

> Ozone 把平台相关的代码挪到以下接口之后：

* `PlatformWindow` represents a window in the windowing system underlying
  chrome. Interaction with the windowing system (resize, maximize, close, etc)
  as well as dispatch of input events happens via this interface. Under aura, a
  `PlatformWindow` corresponds to a `WindowTreeHost`. Under mojo, it corresponds
  to a `NativeViewport`. On bare hardware, the underlying windowing system is
  very simple and a platform window corresponds to a physical display.

> * `PlatformWindow` 表示 Chrome 所依赖的底层窗口系统中的一个窗口。与窗口系统的交互（调整大小、最大化、关闭等）以及输入事件的分发，都通过该接口进行。在 aura 之下，一个 `PlatformWindow` 对应一个 `WindowTreeHost`。在 mojo 之下，它对应一个 `NativeViewport`。在裸硬件上，底层窗口系统非常简单，一个平台窗口就对应一台物理显示器。

* `SurfaceFactoryOzone` is used to create surfaces for the Chrome compositor to
  paint on using EGL/GLES2 or Skia.

> * `SurfaceFactoryOzone` 用于创建表面（surface），供 Chrome 合成器使用 EGL/GLES2 或 Skia 在其上进行绘制。

* `GpuPlatformSupportHost` provides the platform code
  access to IPC between the browser & GPU processes. Some platforms need this
  to provide additional services in the GPU process such as display
  configuration.

> * `GpuPlatformSupportHost` 让平台代码能够访问浏览器进程与 GPU 进程之间的 IPC。有些平台需要借助它在 GPU 进程中提供诸如显示器配置之类的额外服务。

* `OverlayManagerOzone` is used to manage overlays.

> * `OverlayManagerOzone` 用于管理叠加层（overlay）。

* `InputController` allows to control input devices such as keyboard, mouse or
  touchpad.

> * `InputController` 用于控制输入设备，例如键盘、鼠标或触摸板。

* `SystemInputInjector` converts input into events and injects them to the
  Ozone platform.

> * `SystemInputInjector` 把输入转换为事件，并将它们注入 Ozone 平台。

* `NativeDisplayDelegate` is used to support display configuration & hotplug.

> * `NativeDisplayDelegate` 用于支持显示器配置与热插拔。

* `PlatformScreen` is used to fetch screen configuration.

> * `PlatformScreen` 用于获取屏幕配置。

* `ClipboardDelegate` provides an interface to exchange data with other
applications on the host system using a system clipboard mechanism.

> * `ClipboardDelegate` 提供一个接口，用于借助系统剪贴板机制与宿主系统上的其他应用交换数据。

## Ozone in Chromium

> Chromium 中的 Ozone

Our implementation of Ozone required changes concentrated in these areas:

> 我们实现 Ozone 所需的改动集中在以下几个方面：

* Cleaning up extensive assumptions about use of X11 throughout the tree,
  protecting this code behind the `USE_X11` ifdef, and adding a new `IS_OZONE`
  path that works in a relatively platform-neutral way by delegating to the
  interfaces described above.

> * 清理整棵代码树中大量关于使用 X11 的假设，把这些代码保护在 `USE_X11` 这个 ifdef 之后，并新增一条 `IS_OZONE` 路径——它通过委托给上文所述的各个接口，以相对平台中立的方式工作。

* a `WindowTreeHostOzone` to send events into Aura and participate in display
  management on the host system, and

> * 一个 `WindowTreeHostOzone`，用于向 Aura 发送事件，并参与宿主系统上的显示器管理；以及

* an Ozone-specific flavor of `GLSurfaceEGL` which delegates allocation of
  accelerated surfaces and refresh syncing to the provided implementation of
  `SurfaceFactoryOzone`.

> * 一个 Ozone 专用的 `GLSurfaceEGL` 变体，它把加速表面的分配与刷新同步委托给所提供的 `SurfaceFactoryOzone` 实现。

## Porting with Ozone

> 使用 Ozone 进行移植

Users of the Ozone abstraction need to do the following, at minimum:

> Ozone 抽象层的使用者至少需要完成以下工作：

* Write a subclass of `PlatformWindow`. This class (I'll call it
  `PlatformWindowImpl`) is responsible for window system integration. It can
  use `MessagePumpLibevent` to poll for events from file descriptors and then
  invoke `PlatformWindowDelegate::DispatchEvent` to dispatch each event.

> * 编写一个 `PlatformWindow` 的子类。该类（我称其为 `PlatformWindowImpl`）负责窗口系统集成。它可以使用 `MessagePumpLibevent` 轮询来自文件描述符的事件，然后调用 `PlatformWindowDelegate::DispatchEvent` 来分发每个事件。

* Write a subclass of `SurfaceFactoryOzone` that handles allocating accelerated
  surfaces. I'll call this `SurfaceFactoryOzoneImpl`.

> * 编写一个 `SurfaceFactoryOzone` 的子类，负责分配加速表面。我称其为 `SurfaceFactoryOzoneImpl`。

* Write a subclass of `CursorFactory` to manage cursors, or use the
  `BitmapCursorFactory` implementation if only bitmap cursors need to be supported.

> * 编写一个 `CursorFactory` 的子类来管理光标；如果只需支持位图光标，则可以使用 `BitmapCursorFactory` 这一实现。

* Write a subclass of `OverlayManagerOzone` or just use `StubOverlayManager` if
  your platform does not support overlays.

> * 编写一个 `OverlayManagerOzone` 的子类；如果你的平台不支持叠加层，直接使用 `StubOverlayManager` 即可。

* Write a subclass of `NativeDisplayDelegate` if necessary or just use
  `FakeDisplayDelegate`, and write a subclass of `PlatformScreen`, which is
  used by aura::ScreenOzone then.

> * 如有必要，编写一个 `NativeDisplayDelegate` 的子类，或者直接使用 `FakeDisplayDelegate`；并编写一个 `PlatformScreen` 的子类，随后 aura::ScreenOzone 会用到它。

* Write a subclass of `GpuPlatformSupportHost` or just use
  `StubGpuPlatformSupportHost`.

> * 编写一个 `GpuPlatformSupportHost` 的子类，或者直接使用 `StubGpuPlatformSupportHost`。

* Write a subclass of `InputController` or just use `StubInputController`.

> * 编写一个 `InputController` 的子类，或者直接使用 `StubInputController`。

* Write a subclass of `SystemInputInjector` if necessary.

> * 如有必要，编写一个 `SystemInputInjector` 的子类。

* Write a subclass of `OzonePlatform` that owns instances of
  the above subclasses and provide a static constructor function for these
  objects. This constructor will be called when
  your platform is selected and the returned objects will be used to provide
  implementations of all the ozone platform interfaces.
  If your platform does not need some of the interfaces then you can just
  return a `Stub*` instance or a `nullptr`.

> * 编写一个 `OzonePlatform` 的子类，它持有上述各个子类的实例，并为这些对象提供一个静态构造函数。当你的平台被选中时，该构造函数会被调用，返回的对象将用于提供所有 Ozone 平台接口的实现。
  如果你的平台不需要其中某些接口，那么返回一个 `Stub*` 实例或一个 `nullptr` 即可。

## Adding an Ozone Platform to the build (instructions for out-of-tree ports)

> 将 Ozone 平台加入构建（面向树外移植的说明）

The recommended way to add your platform to the build is as follows. This walks
through creating a new ozone platform called `foo`.

> 把你的平台加入构建的推荐方式如下。下面以创建一个名为 `foo` 的新 Ozone 平台为例逐步说明。

1. Fork `chromium/src.git`.

> 1. 分叉（fork）`chromium/src.git`。

2. Add your implementation in `ui/ozone/platform/` alongside internal platforms.

> 2. 把你的实现添加到 `ui/ozone/platform/` 中，与内置平台放在一起。

3. Patch `ui/ozone/ozone_extra.gni` to add your `foo` platform.

> 3. 修改 `ui/ozone/ozone_extra.gni`，加入你的 `foo` 平台。

## Building with Ozone

> 使用 Ozone 构建

### Chrome OS - ([waterfall](https://build.chromium.org/p/chromium.chromiumos/waterfall?builder=Linux+ChromiumOS+Ozone+Builder&builder=Linux+ChromiumOS+Ozone+Tests+%281%29&builder=Linux+ChromiumOS+Ozone+Tests+%282%29&reload=none))

> ### Chrome OS -（[构建瀑布视图](https://build.chromium.org/p/chromium.chromiumos/waterfall?builder=Linux+ChromiumOS+Ozone+Builder&builder=Linux+ChromiumOS+Ozone+Tests+%281%29&builder=Linux+ChromiumOS+Ozone+Tests+%282%29&reload=none)）

To build `chrome`, do this from the `src` directory:

> 要构建 `chrome`，请在 `src` 目录下执行：

``` shell
gn args out/OzoneChromeOS --args="use_ozone=true target_os=\"chromeos\""
ninja -C out/OzoneChromeOS chrome
```

Then to run for example the X11 platform:

> 然后，例如要运行 X11 平台：

``` shell
./out/OzoneChromeOS/chrome --ozone-platform=x11
```

### Embedded

> 嵌入式

**Warning: Only some targets such as `content_shell` or unit tests are
currently working for embedded builds.**

> **警告：对于嵌入式构建，目前只有部分目标（例如 `content_shell` 或单元测试）是可用的。**

To build `content_shell`, do this from the `src` directory:

> 要构建 `content_shell`，请在 `src` 目录下执行：

``` shell
gn args out/OzoneEmbedded --args="use_ozone=true toolkit_views=false"
ninja -C out/OzoneEmbedded content_shell
```

Then to run for example the headless platform:

> 然后，例如要运行 headless 平台：

``` shell
./out/OzoneEmbedded/content_shell --ozone-platform=headless \
                                  --ozone-dump-file=/tmp/
```

### Linux Desktop - ([X11 waterfall](https://ci.chromium.org/p/chromium/builders/try/linux-rel) &&
[Wayland waterfall](https://ci.chromium.org/p/chromium/builders/try/linux-wayland-rel))

> ### Linux 桌面 -（[X11 构建瀑布视图](https://ci.chromium.org/p/chromium/builders/try/linux-rel) &&
> [Wayland 构建瀑布视图](https://ci.chromium.org/p/chromium/builders/try/linux-wayland-rel)）

By default, Linux enables the following Ozone backends - X11, Wayland and Headless.

> 默认情况下，Linux 会启用以下 Ozone 后端——X11、Wayland 和 Headless。

If you want to disable Ozone/X11 in the build, do this from the `src` directory:

> 如果你想在构建中禁用 Ozone/X11，请在 `src` 目录下执行：

``` shell
gn args out/OzoneLinuxDesktop --args="ozone_platform_x11=false"
ninja -C out/OzoneLinuxDesktop chrome
```

If you want to disable all, but Wayland Ozone backend, do this from the `src` directory:

> 如果你想禁用除 Wayland Ozone 后端之外的所有后端，请在 `src` 目录下执行：

``` shell
gn args out/OzoneLinuxDesktop --args="ozone_auto_platforms=false ozone_platform_wayland=true"
ninja -C out/OzoneLinuxDesktop chrome
```

Chrome/Linux uses X11 Ozone backend by default. Thus, simply start the browser without any parameters:

> Chrome/Linux 默认使用 X11 Ozone 后端。因此，不带任何参数直接启动浏览器即可：

``` shell
./out/OzoneLinuxDesktop/chrome
```

Or run for example the Wayland platform:

> 或者，例如运行 Wayland 平台：

``` shell
./out/OzoneLinuxDesktop/chrome --ozone-platform=wayland
```

### GN Configuration notes

> GN 配置说明

You can turn properly implemented ozone platforms on and off by setting the
corresponding flags in your GN configuration. For example
`ozone_platform_headless=false ozone_platform_drm=false` will turn off the
headless and DRM (GBM) platforms.
This will result in a smaller binary and faster builds. To turn ALL platforms
off by default, set `ozone_auto_platforms=false`.

> 你可以通过在 GN 配置中设置相应的标志，来开启或关闭实现正确的 Ozone 平台。例如
`ozone_platform_headless=false ozone_platform_drm=false` 会关闭 headless 和 DRM（GBM）平台。
这会带来更小的二进制文件和更快的构建速度。要让所有平台在默认情况下全部关闭，请设置 `ozone_auto_platforms=false`。

You can also specify a default platform to run by setting the `ozone_platform`
build parameter. For example `ozone_platform="x11"` will make X11 the
default platform when `--ozone-platform` is not passed to the program.
If `ozone_auto_platforms` is true then `ozone_platform` is set to `headless`
by default.

> 你也可以通过设置 `ozone_platform` 这一构建参数来指定默认运行的平台。例如 `ozone_platform="x11"` 会在程序未传入 `--ozone-platform` 时让 X11 成为默认平台。
如果 `ozone_auto_platforms` 为 true，则 `ozone_platform` 默认为 `headless`。

## Running with Ozone

> 使用 Ozone 运行

Specify the platform you want to use at runtime using the `--ozone-platform`
flag. For example, to run `content_shell` with the DRM (GBM) platform:

> 在运行时使用 `--ozone-platform` 标志指定你想使用的平台。例如，要以 DRM（GBM）平台运行 `content_shell`：

``` shell
content_shell --ozone-platform=drm
```

Caveats:

> 注意事项：

* `content_shell` always runs at 800x600 resolution.

> * `content_shell` 始终以 800x600 分辨率运行。

* For the DRM (GBM) platform, you may need to terminate your X server (or any other
  display server) prior to testing.

> * 对于 DRM（GBM）平台，测试之前你可能需要先终止你的 X 服务器（或任何其他显示服务器）。

* During development, you may need to configure
  [sandboxing](linux/sandboxing.md) or to disable it.

> * 在开发过程中，你可能需要配置[沙箱](linux/sandboxing.md)，或者将其禁用。

## Ozone Platforms

> Ozone 平台

### Headless

> Headless（无头）

This platform
draws graphical output to a PNG image (no GPU support; software rendering only)
and will not output to the screen. You can set
the path of the directory where to output the images
by specifying `--ozone-dump-file=/path/to/output-directory` on the
command line:

> 该平台把图形输出绘制成 PNG 图像（不支持 GPU；仅软件渲染），并且不会输出到屏幕上。你可以在命令行上通过指定 `--ozone-dump-file=/path/to/output-directory` 来设置输出图像所在目录的路径：

``` shell
content_shell --ozone-platform=headless \
              --ozone-dump-file=/tmp/
```

### DRM/GBM

> DRM/GBM

This is Linux direct rending with acceleration via mesa GBM & linux DRM/KMS
(EGL/GLES2 accelerated rendering & modesetting in GPU process) and is in
production use on [Chrome OS](https://www.chromium.org/chromium-os).

> 这是通过 mesa GBM 与 Linux DRM/KMS 实现加速的 Linux 直接渲染（在 GPU 进程中进行 EGL/GLES2 加速渲染与模式设置），并已在 [Chrome OS](https://www.chromium.org/chromium-os) 上投入生产使用。

Note that all Chrome OS builds of Chrome will compile and attempt to use this.
See [Building Chromium for Chromium OS](https://www.chromium.org/chromium-os/how-tos-and-troubleshooting/building-chromium-browser) for build instructions.

> 请注意，所有 Chrome OS 版本的 Chrome 构建都会编译并尝试使用它。
构建说明参见[为 Chromium OS 构建 Chromium](https://www.chromium.org/chromium-os/how-tos-and-troubleshooting/building-chromium-browser)。

### Cast

> Cast

This platform is used for
[Chromecast](https://www.google.com/intl/en_us/chromecast/).

> 该平台用于 [Chromecast](https://www.google.com/intl/en_us/chromecast/)。

### X11

> X11

This platform provides support for the [X window system](https://www.x.org/).

> 该平台提供对 [X 窗口系统](https://www.x.org/) 的支持。

X11 is the default Ozone backend. You can try to compile and run it with the following
configuration:

> X11 是默认的 Ozone 后端。你可以用以下配置尝试编译并运行它：

``` shell
gn args out/OzoneX11
ninja -C out/OzoneX11 chrome
./out/OzoneX11/chrome
```

### Wayland

> Wayland

This platform provides support for the
[Wayland](http://wayland.freedesktop.org/) display protocol. It was
initially developed by Intel as
[a fork of chromium](https://github.com/01org/ozone-wayland)
and then partially upstreamed.

> 该平台提供对 [Wayland](http://wayland.freedesktop.org/) 显示协议的支持。它最初由 Intel 作为[一个 Chromium 分叉](https://github.com/01org/ozone-wayland)开发，随后部分合入了上游。

Currently, the Ozone/Wayland is actively being developed by Igalia in
the Chromium mainline repository with some features missing at the moment. The
progress can be tracked in the [issue #578890](https://crbug.com/578890).

> 目前，Ozone/Wayland 正由 Igalia 在 Chromium 主线仓库中积极开发，眼下尚有一些功能缺失。进展可在 [issue #578890](https://crbug.com/578890) 中跟踪。

Below are some quick build & run instructions. It is assumed that you are
launching `chrome` from a Wayland environment such as `weston`. Execute the
following commands (make sure a system version of gbm and drm is used, which
are required by Ozone/Wayland by design, when running on Linux platforms.):

> 下面是一些简明的构建与运行说明。这里假定你是在诸如 `weston` 这样的 Wayland 环境中启动 `chrome`。请执行以下命令（在 Linux 平台上运行时，请确保使用系统版本的 gbm 和 drm——按设计，Ozone/Wayland 需要它们。）：

Please note that the Wayland Ozone backend is built by default unless
`ozone_auto_platforms=false` is set (the same as the X11 Ozone backend).

> 请注意，除非设置了 `ozone_auto_platforms=false`，否则 Wayland Ozone 后端默认会被构建（这与 X11 Ozone 后端相同）。

``` shell
gn args out/OzoneWayland
ninja -C out/OzoneWayland chrome
./out/OzoneWayland/chrome --ozone-platform=wayland
```

Native file dialogs are currently supported through the GTK toolkit. That
implies that the browser is compiled with glib and gtk enabled. Please
append the following gn args to your configuration:

> 原生文件对话框目前通过 GTK 工具包提供支持。这意味着浏览器在编译时启用了 glib 和 gtk。请在你的配置中追加以下 gn 参数：

``` shell
use_ozone=true
use_system_minigbm=true
use_system_libdrm=true
use_xkbcommon=true
use_glib=true
use_gtk=true
```

Running some test suites requires a Wayland server. If you're not running one
you can use a locally compiled version of Weston or Mutter. This is what the
build bots do. Please note that this is required for interactive_ui_tests, as
those tests use a patched version of the compositor.

> 运行某些测试套件需要一个 Wayland 服务器。如果你没有在运行，可以使用本地编译的 Weston 或 Mutter 版本。构建机器人（build bot）就是这么做的。请注意，这对 interactive_ui_tests 是必需的，因为这些测试使用了一个打过补丁的合成器版本。

Mutter and its dependencies are not checked out by default to keep the disk
usage optimal for most developers. In order to checkout mutter, add the
`checkout_mutter` custom var in your .gclient file and set it to `True` and run `gclient sync`.

> 为了让大多数开发者的磁盘占用保持最优，Mutter 及其依赖默认不会被检出。要检出 mutter，请在你的 .gclient 文件中添加 `checkout_mutter` 自定义变量并将其设为 `True`，然后运行 `gclient sync`。

```
solutions = [
  {
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "name": "src",
    "custom_deps": {},
    "custom_vars": {
      "checkout_mutter": True,
    },
  },
]
```

For weston, simply add this to your gn args:

> 对于 weston，只需把以下内容加入你的 gn args：

``` shell
use_bundled_weston = true
```

Then after building the test executable, run the xvfb.py wrapper script and tell
it to start the compositor with the tests:

> 然后在构建完测试可执行文件之后，运行 xvfb.py 封装脚本，并让它随测试一起启动合成器：

``` shell
cd out/debug  # or your out directory
```
``` shell
# For weston
../../testing/xvfb.py --use-weston --no-xvfb ./views_unittests --ozone-platform=wayland
```
``` shell
# For mutter
../../testing/xvfb.py --use-mutter --no-xvfb ./views_unittests --ozone-platform=wayland
```

Feel free to discuss with us on freenode.net, `#ozone-wayland` channel or on
`ozone-dev`, or on `#ozone-wayland-x11` channel in [chromium slack](https://www.chromium.org/developers/slack).

> 欢迎在 freenode.net 的 `#ozone-wayland` 频道或 `ozone-dev` 上，或在 [chromium slack](https://www.chromium.org/developers/slack) 中的 `#ozone-wayland-x11` 频道上与我们交流讨论。

### Caca

> Caca

This platform
draws graphical output to text using
[libcaca](http://caca.zoy.org/wiki/libcaca)
(no GPU support; software
rendering only). In case you ever wanted to test embedded content shell on
tty.
It has been
[removed from the tree](https://codereview.chromium.org/2445323002/) and is no
longer maintained but you can
[build it as an out-of-tree port](https://github.com/fred-wang/ozone-caca).

> 该平台使用 [libcaca](http://caca.zoy.org/wiki/libcaca) 把图形输出绘制为文本（不支持 GPU；仅软件渲染）。以防你曾想在 tty 上测试嵌入式 content shell。
它已被[从代码树中移除](https://codereview.chromium.org/2445323002/)，不再维护，但你可以[把它作为树外移植来构建](https://github.com/fred-wang/ozone-caca)。

Alternatively, you can try the latest revision known to work. First, install
libcaca shared library and development files. Next, move to the git revision
`0e64be9cf335ee3bea7c989702c5a9a0934af037`
(you will probably need to synchronize the build dependencies with
`gclient sync --with_branch_heads`). Finally, build and run the caca platform
with the following commands:

> 或者，你可以尝试已知可用的最新修订版本。首先，安装 libcaca 共享库与开发文件。接着，切换到 git 修订版本
`0e64be9cf335ee3bea7c989702c5a9a0934af037`
（你很可能需要用 `gclient sync --with_branch_heads` 同步构建依赖）。最后，用以下命令构建并运行 caca 平台：

``` shell
gn args out/OzoneCaca \
        --args="use_ozone=true ozone_platform_caca=true use_sysroot=false ozone_auto_platforms=false toolkit_views=false"
ninja -C out/OzoneCaca content_shell
./out/OzoneCaca/content_shell
```

  Note: traditional TTYs are not the ideal browsing experience.<br/>
  ![Picture of a workstation using Ozone/caca to display the Google home page in a text terminal](./images/ozone_caca.jpg)

> 注意：传统 TTY 并不是理想的浏览体验。<br/>
> ![一台工作站使用 Ozone/caca 在文本终端中显示 Google 主页的图片](./images/ozone_caca.jpg)

### drm

> drm

Ash-chrome client implementation.

> Ash-chrome 客户端实现。

### flatland

> flatland

For fuchsia.

> 用于 Fuchsia。

## Communication

> 交流渠道

There is a public mailing list:
[ozone-dev@chromium.org](https://groups.google.com/a/chromium.org/forum/#!forum/ozone-dev)

> 有一个公开的邮件列表：
[ozone-dev@chromium.org](https://groups.google.com/a/chromium.org/forum/#!forum/ozone-dev)
