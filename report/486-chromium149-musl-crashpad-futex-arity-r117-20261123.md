# Chromium 149 R117 的 Crashpad futex 参数适配（2026-11-23）

## 失败位置

R116 在 `third_party/crashpad/crashpad/client/crashpad_client_linux.cc` 编译时
停止：当前 T490 临时 LSS 头只声明四参数 `sys_futex`，而 Crashpad 两处调用仍
传六个参数：

```text
error: no matching function for call to 'sys_futex'
candidate function ... requires 4 arguments, but 6 were provided
```

失败动作是 `[605/23688]`，对象为
`obj/third_party/crashpad/crashpad/client/client/crashpad_client_linux.o`。

## 最小修复

补丁 [0030](patches/0030-crashpad-musl-futex-arity.patch) 只移除
`FUTEX_WAIT_PRIVATE` 和 `FUTEX_WAKE_PRIVATE` 调用中未使用的 `uaddr2/val3`
参数，使调用匹配当前 LSS 的四参数接口。内核 futex 操作码和 timeout 保持不变。

远端修复位置：

```text
/home/mo/chromium-src-149-alpine/third_party/crashpad/crashpad/client/crashpad_client_linux.cc
```

修复后继续使用同一 `out/tryframe-root4`、AArch64/musl、`ninja -j8 chrome`。
