# Chromium 149 R119 的 Dawn Tint GLSL writer 配置修复（2026-11-23）

## 失败位置

R118 将 Dawn OpenGL 的 Khronos 头路径修正后，构建进入
`third_party/dawn/src/dawn/native/opengl/ShaderModuleGL.cpp`，但 GN 输出配置
关闭了 Tint GLSL writer：

```text
tint_build_glsl_writer = false
```

因此 `ShaderModuleGL.cpp` 中引用的 `tint::glsl::writer::Version`、
`CombinedTextureSamplerInfo`、`TextureBuiltinsFromUniformOptions` 等类型全部缺失。
该组合是 Dawn OpenGL backend 与 Tint feature 配置不一致，不是 x-kernel 运行时错误。

## 最小修复

补丁 [0032](patches/0032-enable-dawn-tint-glsl-writer.patch) 将同一 GN 输出的
`tint_build_glsl_writer` 改为 `true`，保留 `tint_build_glsl_validator=false`。
这样只开启 OpenGL shader writer 所需的生成/编译路径，不改变 Chromium runtime
参数。

远端配置：

```text
/home/mo/chromium-src-149-alpine/out/tryframe-root4/args.gn
```

需要让 GN 重新生成后继续 `ninja -j8 chrome`；最终链接仍待通过。
