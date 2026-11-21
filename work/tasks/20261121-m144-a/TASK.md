# 144-A 返回列表时恢复键盘选中行的视口（WorkspaceView）

## 背景
真机验证波 142 时发现：跨页返回后，`scrollPositions` 只承载指针滚动；键盘选择触发的 `proxy.scrollTo` 不写回 `ScrollPosition`，于是返回材料/行动列表时选中环仍在原行、视口却回到顶部。修复：列表 `onAppear` 时若保留的键盘选中 id 非空，滚动到该行（与既有选中滚动同一模式）。

## 改动
- WorkspaceView.swift 新增私有 `restoreKeyboardScroll(proxy:id:)`：id 非空时 `Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: .center) }`，附注释说明键盘滚动不写回 ScrollPosition。
- 材料页 onAppear（原 `requestMaterialListFocus()`）改为调用焦点请求 + `restoreKeyboardScroll(proxy: proxy, id: materialKeyboardFocus.id)`。
- 行动页 onAppear（原 `requestActionListFocus()`）同样追加 `restoreKeyboardScroll(proxy: proxy, id: actionKeyboardHighlightID)`。
- 筛选切换仍会清空选中 id（既有 onChange），因此不会把一个筛选的视口错用到另一个筛选。

## 验证
`xcrun --sdk macosx swiftc -parse` 真实退出码 0；行为验证留集成后真机（返回材料页查看视口停在选中行）。不跑 swift build/test（波次批处理）。