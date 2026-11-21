# 142-A 添加下一步表单的键盘语义（140 遗留）

## 背景
140-B 记录的唯一遗留：`NextActionFormSheet`（WorkspaceActivityViews.swift:1479）没有 Esc，输入框打开后不聚焦，主按钮不响应回车。按 140 统一约定补齐。

## 改动
- 新增 `@FocusState private var titleFocused`，标题框 `.focused`，sheet 出现后 100ms 置焦。
- 取消按钮挂 `.keyboardShortcut(.cancelAction)`。
- 「重试挂接」与「添加」挂 `.keyboardShortcut(.defaultAction)`（二选一渲染，同一时刻只有一个默认按钮）。
- 保留原有 `.onSubmit { submit() }`；`submit()` 的 busy 守卫保证 Enter 双通道触发不会重复创建（命令 id 相同且 busy 立即置位）。
- 布局「取消左 — Spacer — 主按钮右」原本已符合约定，未动。

## 验证
`xcrun swiftc -parse` 退出码 0。按波次批处理约定不单独构建；合并后集成构建 + 全量测试。