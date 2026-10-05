# `scripts/testpage/` — 测试页目录

> **2026-09-22 起，guest 侧统一使用本目录下的「官方三页套」。**
> 旧的 `local-check.html` 仍在（`ppm_assert.py --profile legacy` 的几何来源），
> 但它只用于历史轮次复现，不再作为新的测试页。

## 1. 页面清单

| 文件 | 名称 | 内容 | 是否需要输入 | 对应判据 profile |
|---|---|---|---|---|
| `index.html` | 静态渲染验收 | 四色块同行 / 表格 / 列表+SVG / 表单控件；**无脚本、无外部资源、无时间依赖**，页面自述"截图结果应逐队一致" | 否 | `--profile official-index` |
| `interaction.html` | JavaScript 交互 | A 段自检（T1–T6 + F1，需点「运行自检」）＋ B 段输入交互（键入 `hello x-kernel`、鼠标点击计数 +1、跳转 `layout.html`） | **是**（点击 / 键入） | `--profile official-interaction` |
| `layout.html` | CSS 布局与渲染 | C1 flex / C2 grid / C3 盒模型 / C4 圆角 / C5 斑马纹 / C6 对齐；**加载即自动测量并给出 6/6 结论条** | 否（自动跑） | `--profile official-layout` |

三页互相有超链接（`interaction.html` ↔ `layout.html`），所以**必须整目录注入**，
只塞一个 `index.html` 会让"页面跳转"这项直接 404。

## 2. guest 内落点与启动

| 项 | 值 |
|---|---|
| 落点 | `/usr/share/html-test/{index,interaction,layout}.html`（mode 0644） |
| 兼容副本 | `/root/index.html` = 本轮**入口页**的副本（早期 autorun 只认这个路径） |
| 默认入口 | `file:///usr/share/html-test/index.html` |
| 换入口 | `PAGE_URL=file:///usr/share/html-test/layout.html bash t490_round.sh ...` |

注入由 `scripts/t490/t490_inject_pages.sh` 完成：整套写盘 + **读回逐字节自比**
（`debugfs dump` → `cmp`），任一页不一致就 `PAGE_SET_FAIL` 并让调用方硬失败。

## 3. 参考图（`reference/`）

| 文件 | 用途 |
|---|---|
| `ref-official-<page>-1280x800.png` / `-640x480.png` | 本机无头 Chrome 渲染的"应该长什么样"，两种 screendump 画幅各一套 |
| `ref-1280x800.png` / `ref-640x480*.png` | **legacy**：旧 `local-check.html`（v1.1）的参照图，保留供历史判据对照 |

参考图是 `ppm_assert.py` 里**所有官方页判据常量的来源**（不是从 CSS 反推的）。
重新生成：

```bash
# 1) 渲染（本机 Chrome 无头，DPR=1，与 screendump 同画幅）
"/c/Program Files/Google/Chrome/Application/chrome.exe" --headless=new --disable-gpu \
  --hide-scrollbars --force-device-scale-factor=1 --virtual-time-budget=2500 \
  --window-size=1280,800 --screenshot="$PWD/reference/ref-official-index-1280x800.png" \
  "file:///<repo>/中电杯/scripts/testpage/index.html"
# 2) 转 PPM（判据只吃 P6），再跑判据
python3 scripts/png2ppm.py --out-dir tmp/ref-ppm scripts/testpage/reference/ref-official-*.png
python3 scripts/t490/ppm_assert.py tmp/ref-ppm/ref-official-index-640x480.ppm --profile official-index
```

## 4. 三条使用注意（都是实测踩出来的）

1. **首屏取舍**：`layout.html` 的"6/6 通过"结论条在整页 y≈1450 处，1280×800 的
   screendump **看不到**（实测绿字只剩 30 px 噪声）。C1/C2 网格在两种画幅下都可见，
   但结论条要用更高窗口或滚动后才截得到。
2. **`interaction.html` 的结论必须有一次真实输入**：未点击时结论条是灰的
   （实测绿底 36 px），点击后 60056 px。所以在没有键鼠输入的轮次里，它的自检结果
   判不出来 —— 判据里该项归 `input` 组，不给 `--expect-input` 就只报告不卡关。
3. **别对 `index.html` 做双帧差分**：它是纯静态页，两帧必然 0 差异，
   那不是 renderer 死了。JS 存活的像素级证据改看结论条颜色。
