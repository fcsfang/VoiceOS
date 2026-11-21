# 154-A 自动入口页分组（RecordingInbox.swift）

## 背景
设置语言推广到工具页。自动入口页当前：标题下三段常驻机制说明、一排主按钮、两个文件夹平铺行、失败素材详情与底部操作，混杂在同一节奏里。按「每类信息一张卡 + 行原语 + 渐进披露」重组，不改任何行为。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/RecordingInbox.swift

## 可用原语（WorkspaceDesign.swift）
`WorkspaceSettingsCard` / `WorkspaceSettingsRow` / `WorkspaceSettingsNavRow` / `WorkspaceSettingsValueRow` / `WorkspaceListDivider` / `WorkspaceNoticeText`。

## 分组方案
1. **页头**：WorkspaceHeading/eyebrow 原样；标题下一行短说明（保留原文第一句），其余机制说明（Qwen 全转写、只接新增/更新、固定录制格式）折叠进一张 `WorkspaceSettingsCard(title:"工作方式", subtitle:"接收与处理的规则")` 内的 DisclosureGroup（默认收起），内容逐字保留。
2. **接收入口**：`WorkspaceSettingsCard(title:"接收位置", subtitle:"VoiceOS 收件箱与语音备忘录")`：
   - 顶部行放主按钮（启用收件箱 / 其他文件夹… / 连接语音备忘录…），作为行内容（20/12）。
   - 每个文件夹一行 `WorkspaceSettingsRow`：title=文件夹名（VoiceOS 收件箱/语音备忘录），subtitle=路径（可选中），trailing=打开文件夹（quiet）+ 移除入口（destructive）。
   - 未启用/为空时的原空态保留在卡内。
3. **需要处理**：失败或待重试素材的现有详情块移入 `WorkspaceSettingsCard(title:"需要处理", subtitle:"失败或已完成待确认的素材")`，每条为一行（标题、状态说明、动作 重试/不再处理）；无内容时整卡不渲染。
4. **底部操作**：检查新素材 / 重试未完成素材 改为卡内或卡下的一行（保持原动作与 disabled）；恢复状态提示（「已恢复 N 份…」）作为卡内说明或 Notice。
- 页列限宽 680；所有文案、动作、状态判断、错误详情与按钮逐字保留（除为分组新增的卡标题/说明）。

## 约束
- 不改逻辑与文案（新增卡标题/说明除外）；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 先 grep 全文并列出原区块映射；跨文件（VoiceOSApp 中嵌入调用）不改。

## 回报
提交哈希、区块映射、保留原样项、parse 退出码、diff --stat。