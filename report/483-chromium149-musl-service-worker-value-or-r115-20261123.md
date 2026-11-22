# Chromium 149 R115 的 ServiceWorker `value_or({})` 兼容修复（2026-11-23）

## 失败位置

R114 在修复 crash-report Mojo 常量后继续编译，在 `service_worker_version.cc`
处停止：

```text
content/browser/service_worker/service_worker_version.cc:850:51:
error: no matching member function for call to 'value_or'
request_timeouts_.erase(request->timeout_iter.value_or({}));
```

`timeout_iter` 的类型是
`std::optional<std::set<InflightRequestTimeoutInfo>::iterator>`。当前 Chromium
构建使用的 libc++/musl 组合不能从空初始化列表推断 `value_or` 的 `_Up` 类型，
因此这与 R110 `full_card_request.cc` 的同类缺陷属于同一兼容性类别。

## 最小修复

补丁 [0027](patches/0027-chromium-musl-service-worker-value-or.patch) 将默认值
改为同一 set 的 `end()` 迭代器，使模板参数明确，同时保留原有“非 optional 迭代器”
分支语义。该分支只有在 optional 没有值时才使用默认值；正常请求路径仍使用真实
`timeout_iter`。

远端临时修复位置：

```text
/home/mo/chromium-src-149-alpine/content/browser/service_worker/service_worker_version.cc:850
```

修复后以同一 `out/tryframe-root4` 重新执行 `ninja -j8 chrome`。最终对象/链接仍
待返回码为 0 后确认。

## 证据

- T490 `/tmp/chrome-build-r114-bg.log`：R114 `BUILD_RC=1`。
- 停止动作：`[103/23842]` 对应 ServiceWorker 编译，随后并行对象完成但 Ninja 失败。
- 生成上下文：`service_worker_version.h:921` 的 optional set iterator。
