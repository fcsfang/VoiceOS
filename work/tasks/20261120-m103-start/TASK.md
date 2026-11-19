# 波 103-A：启动页视觉系统整改

## 背景

波 102 统一了首页、材料、行动、设置、监测、主题六屏的按钮、徽标与页头。只读审计（2026-11-20）显示 `TaskInitiationView.swift` 仍停在旧词汇：系统蓝 tint 主按钮 5 处、无样式裸按钮 7 处、无样式下拉胶囊 1 处、手写状态胶囊 1 个、tinted 面板无边框。

## 范围

仅 `Sources/VoiceOSApp/TaskInitiationView.swift`。行为、accessibilityIdentifier、键盘快捷键、文案不变。

## 改动

| 位置 | 改动 |
| --- | --- |
| 页头（原 L54） | `WorkspaceHeading` → `WorkspacePageHeading(title: "启动")` |
| `generateStyle`（新增） | 组合器主按钮按状态计算：无选中记录或 `captureOnly` 时为 `.workspacePrimary`，其余为 `.workspaceSecondary`，保证同屏至多一个主按钮 |
| 生成按钮（原 L137） | `.borderedProminent + tint(accent)` → `.buttonStyle(generateStyle)` |
| 最近材料菜单（原 L112-120） | 自定义 label + `.menuStyle(.button).buttonStyle(.workspaceSecondary)`（同 `WorkspaceSourceView.swift:611` 先例） |
| 字数计数（原 L122） | 仍是 caption，`.secondary` → `palette.tertiaryText`（超限保持 danger） |
| 澄清（原 L208/L210） | 按回答生成 → `.workspacePrimary`；先不问 → `.workspaceSecondary` |
| 回答卡（原 L235/L238/L245） | 面板加 hairline；复制回答 → `.workspacePrimary`；归档保存 → `.workspaceSecondary` |
| 直接回答（原 L269/L282） | 直接回答 → `.workspaceQuiet`；复制这段回答 → `.workspaceQuiet` |
| 材料编辑器（原 L323/L326/L336） | 复制 → `.workspaceSecondary`（该状态唯一主操作是确认）；确认这是我要的 → `.workspacePrimary`；归档这条记录 → `.workspaceSecondary` |
| 这一步记录（原 L374） | 保存这一步 → `.workspaceSecondary`（确认按钮同屏为 primary） |
| 依据行（原 L184） | `.borderless` → `.workspaceQuiet` |
| 直接回答面板（原 L280） | 加 hairline，保持 `palette.selection` 底色 |
| 不保存这条启动记录（原 L469） | `.workspaceQuiet`（三处复用同一按钮定义） |
| `statusChip`（原 L475-479） | 改为 `WorkspaceBadge` 包装：已确认/已保存/已复制 accent，其余 neutral；已归档 neutral |

## 验证

- `swift build -j 2`：build_exit=0
- `swift test -j 2`：test_exit=0，Executed 661 tests, with 0 failures
- 日志：`/tmp/m103-start-build.log`、`/tmp/m103-start-test.log`

## 取舍与风险

- 未重启应用、未截图验证。Menu 的 `.menuStyle(.button)` + 自定义 ButtonStyle 沿用仓内先例；若某系统版本忽略自定义样式，会退化为系统描边按钮（仍可见，不再是裸胶囊）。
- 「复制」与「保存这一步」不做主按钮：材料编辑器同一状态里「确认这是我要的」是该状态唯一主按钮（审计要求同屏至多一个）。
- 生成按钮的层级随选中记录变化，是唯一新增的派生判断；只看 `selected` 是否存在、`route == .captureOnly`、`isClarifying`，不引入新状态。
- `statusChip` 的 tone 由 `record.isConfirmed` 与调用点参数决定，不按文案字符串匹配。
- `WorkspaceBadge` 自带 `accessibilityLabel(text)`，与旧胶囊暴露的文本一致；所有 `accessibilityIdentifier` 未动。