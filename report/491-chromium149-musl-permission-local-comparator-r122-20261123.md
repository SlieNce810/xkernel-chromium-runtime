# Chromium 149 R122 的 PermissionRequest raw_ref 局部 comparator 修复（2026-11-23）

R121 曾尝试修改公共 `raw_ref.h` 的 `std::less`，但这会使整个 Chromium 输出树的
依赖头全部失效并触发约四万动作重编。为保持构建可推进，R122 将同一 const lookup
语义移到唯一需要它的 PermissionRequest map：

```cpp
std::map<base::raw_ref<PermissionRequest>, PermissionRequestSource,
         PermissionRequestRefLess>
```

局部透明 comparator 提供 raw_ref/raw_ref、raw_ref/const PermissionRequest 和
const PermissionRequest/raw_ref 三种比较。公共 `raw_ref.h` 恢复为原始内容，已有
对象可以继续复用；补丁 [0034](patches/0034-permission-request-local-raw-ref-comparator.patch)
只影响权限管理器头及其直接依赖。

这保留 R121 试验揭示的修复语义，同时避免不必要的全树重编。R122 需要继续执行
同一 `out/tryframe-root4` 的 `ninja -j8 chrome` 验证。
