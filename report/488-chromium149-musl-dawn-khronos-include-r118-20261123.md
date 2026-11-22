# Chromium 149 R118 的 Dawn Khronos 头路径修复（2026-11-23）

## 失败位置

R117 在 Dawn OpenGL 自动生成对象处停止：

```text
FAILED: obj/third_party/dawn/src/dawn/native/sources/OpenGLFunctionsBase_autogen.o
gen/third_party/dawn/src/dawn/native/opengl/opengl_platform_autogen.h:2:10:
fatal error: 'KHR/khrplatform.h' file not found
```

仓库实际已有：

```text
third_party/khronos/KHR/khrplatform.h
```

但 Dawn 的 `third_party/dawn/third_party/EGL-Registry/BUILD.gn` 只暴露
`${dawn_egl_registry_dir}/api`，该不完整源快照没有对应的 Khronos 头。

## 最小修复

补丁 [0031](patches/0031-dawn-khronos-platform-include-path.patch)：

- 将 `third_party/khronos` 加入 `khronos_headers_public.include_dirs`；
- 将 `khronos_platform` 的 source 指向仓库已有的
  `third_party/khronos/KHR/khrplatform.h`。

这保持 `<KHR/khrplatform.h>` 的现有 include 语义，只修正目标的 include/source
映射，不复制或修改 Khronos 头内容。

远端源码路径：

```text
/home/mo/chromium-src-149-alpine/third_party/dawn/third_party/EGL-Registry/BUILD.gn
```

修复后需要让 GN 重新生成，再继续同一 `out/tryframe-root4` 的 `ninja -j8 chrome`。
