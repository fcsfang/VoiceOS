# 144-F 无障碍语义小修（Onboarding / ReflectionGraphView）

## 背景
无障碍只读发现两条：Onboarding 行用 `accessibilityElement(children:.combine)` 包住了带操作按钮的行，VoiceOver 无法到达按钮；认知地图节点按钮的自定义选中态只有视觉（边框/勾选），没有 `.isSelected` 语义。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/Onboarding.swift
- Sources/VoiceOSApp/ReflectionGraphView.swift

## 逐条

### 1. Onboarding 行合成语义
- `Onboarding.swift` 约 236-242 行：行内容 HStack 末尾可能带 `Button(action, action: perform)`，随后整行 `.accessibilityElement(children: .combine)`。改为按有无操作分别处理：
```swift
.accessibilityElement(children: action == nil ? .combine : .contain)
```
（若实际字段名不同按代码调整；目标是：纯说明行保持合成为一句，带按钮的行让 VoiceOver 能聚焦按钮。）确认行内文字仍能被逐个读出、按钮可获得焦点；必要时给说明文字 `.accessibilityLabel` 保持整句。

### 2. 认知地图节点选中语义
- `ReflectionGraphView.swift` 约 473 行 `nodeButton(_:)`：节点被选中时加 `.accessibilityAddTraits(.isSelected)`；若节点有「此前」等上下文状态，可用 `.accessibilityValue` 表达（如「已选中，此前材料」），保持与视觉一致。
- 同文件其它自绘选择控件（约同一函数族）若同样只有视觉选中态（边框/勾选/单选圈），补 `.isSelected` 或 value；grep `selection ==` 与其所在 Button。

## 约束
- 不改业务逻辑、文案与视觉；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 每条先读代码核实现状；机制不符的跳过并记录证据。

## 回报
提交哈希、逐条完成/跳过及原因、parse 退出码、diff --stat。