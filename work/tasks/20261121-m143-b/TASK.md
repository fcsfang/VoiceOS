# 143-B 设计系统收敛：页头三合一、字段表面提升、WorkspaceView/TextCaptureView 应用

## 背景
只读发现：WorkspaceHero（WorkspaceDesign.swift:37-46）、WorkspaceHeading（WorkspaceView.swift:127-134）、WorkspacePageHeading（WorkspaceDesign.swift:660-669）三套页头在 eyebrow tracking（2 vs 1.4）、副标题颜色（.secondary vs palette.secondaryText）、行距（4 vs 3）、间距（12/8/6）上各自漂移，24 个调用点因此不一致；`WorkspaceFieldSurface` 是 TextCaptureView 私有修饰符，其它 12 处字段还在用系统 `.roundedBorder`。本单元负责设计系统层与两个自有文件的落地。

## 文件清单（只允许动这三个）
- Sources/VoiceOSApp/WorkspaceDesign.swift
- Sources/VoiceOSApp/WorkspaceView.swift
- Sources/VoiceOSApp/TextCaptureView.swift

## 逐条

### 1. 页头三合一
- 以 `WorkspacePageHeading` 为唯一实现（保留其 trailing 槽与 EmptyView 便捷初始化）。
- `WorkspaceHero` 与 `WorkspaceHeading` 改为对它的薄包装：`WorkspacePageHeading(eyebrow:title:subtitle:)` + `.textSelection(.enabled)`（两者原来对标题开放文本选择，PageHeading 没有；把 textSelection 加在包装层，视觉参数一律取 PageHeading 的）。删除两者内部重复实现。
- 不改任何调用点签名与文案；24 个调用点的渲染差异（tracking、副标题颜色、行距、间距）统一归零。
- 注意 `WorkspacePageHeading` 的 `@ViewBuilder trailing` 泛型结构，包装层用 EmptyView 分支即可。

### 2. `workspaceFieldSurface()` 提升为设计系统 API
- 把 TextCaptureView.swift:392-404 的 `private struct WorkspaceFieldSurface` 与 `private extension View` 原样迁到 WorkspaceDesign.swift（改为 internal，放在 workspaceEditorSurface 附近），并从 TextCaptureView 删除私有副本。
- TextCaptureView 内原三个调用点（125/237/292 附近）继续可用，无需改调用。
- 新 API 契约（波内其它单元依赖，签名不得改）：`func workspaceFieldSurface() -> some View`，内部实现保持 `textFieldStyle(.plain) + padding(.horizontal,12) + minHeight(WorkspaceMetrics.fieldHeight) + palette.selection 填充 + palette.border 发丝线 + controlRadius`。

### 3. WorkspaceView 应用
- 约 618 与 1263 的 TextField 改为 `.workspaceFieldSurface()`（自行按上下文保留原 `.focused`/`.onSubmit` 等修饰）。
- 约 3423 的 TextEditor 改 `.workspaceEditorSurface()`（现有 workspaceEditorSurface(radius:) API，默认 radius 即可）。
- 约 550 的「取消」（取消选择提醒清单）与约 3016 的「关闭」（待核对提醒同步）补 `.buttonStyle(.workspaceSecondary)`；同弹层主按钮若裸 Button 且为提交语义，补 `.buttonStyle(.workspacePrimary)`（如「现在核对」）。

### 4. TextCaptureView 按钮
- 约 65「稍后继续」补 `.buttonStyle(.workspaceSecondary)`；同层「保存」若已有 workspacePrimary 则不动，若裸 Button 补 `.buttonStyle(.workspacePrimary)`。

## 约束
- 不改业务逻辑、文案、disabled/help/accessibility；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、逐条完成情况、workspaceFieldSurface 最终签名、parse 退出码、diff --stat。