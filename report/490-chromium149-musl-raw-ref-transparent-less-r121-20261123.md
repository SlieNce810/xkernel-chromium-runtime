# Chromium 149 R121 的 raw_ref transparent comparator 修复（2026-11-23）

## 失败位置

R120 在 `components/permissions/permission_request_manager.cc` 编译时停止：

```text
no matching function for call to object of type
'const std::less<base::raw_ref<permissions::PermissionRequest>>'
```

`request_sources_map_` 是：

```cpp
std::map<base::raw_ref<PermissionRequest>, PermissionRequestSource>
```

libc++ 的 heterogeneous `map::find(const PermissionRequest&)` 需要 comparator
同时接受 `raw_ref` 与 `const T&`。当前 `raw_ref.h` 只提供 `T&` 重载，无法绑定
const lookup 参数。

## 最小修复

补丁 [0033](patches/0033-raw-ref-transparent-const-less.patch) 为
`std::less<raw_ref<T, Traits>>` 增加两种 const transparent lookup 重载：

```cpp
operator()(const T&, const raw_ref<T, Traits>&)
operator()(const raw_ref<T, Traits>&, const T&)
```

底层 `raw_ref` 已有 const-safe `<` 运算符，补丁只扩展 comparator 的参数匹配，
不改变指针排序或生命周期语义。

远端修复位置：

```text
/home/mo/chromium-src-149-alpine/base/allocator/partition_allocator/src/partition_alloc/pointers/raw_ref.h
```

R121 需在同一 `out/tryframe-root4` 继续编译以验证该修复并寻找下一处阻断。
