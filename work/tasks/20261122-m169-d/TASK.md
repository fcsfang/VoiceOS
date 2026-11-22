# 169-D 材料详情正文式笔记阅读界面

## 背景（产品文档第一阶段）
产品目标（原文）：我随口说出自己的想法，VoiceOS 帮我整理成一篇愿意重读的笔记。读完以后，我更清楚自己在想什么，也认得出这是我的意思。
第一阶段验收：材料详情打开即为一篇可读、可追溯的思考笔记。169-A/B/C1/C2 已合入 main：域模型+存储（schema 77/包 52）、`MaterialNotePort`+锚定、`MaterialNoteCenter` 编排（`materialNoteStates`/`requestMaterialNote(sourceID:force:)`/`materialNoteForDisplay(sourceID:)`）。本单元只做阅读界面与页面接入。

## 必读
- `docs/product/VoiceOS 产品方向与开发交接：把口述整理成笔记.md` 全文，重点「一份真实材料暴露了什么」「建议怎样改」「打开后的第一眼」「视觉验收」。
- `Sources/VoiceOSApp/WorkspaceSourceView.swift`：readingScrollView 结构、SourceFold、`model.playSpan(_:milliseconds:endMilliseconds:)`、组合读取 `SourcePageReadKey` 与子键门控/`readKeyIsCurrent` 模式。
- `Sources/VoiceOSApp/MaterialNoteCenter.swift`：状态与读取 API（只读消费，不改）。
- `Sources/VoiceOSApp/WorkspaceDesign.swift`：卡片/文字/间距/动效原语。

## 文件清单（只允许动这些）
- 新建 `Sources/VoiceOSApp/MaterialNoteReadingView.swift`
- `Sources/VoiceOSApp/WorkspaceSourceView.swift`（接入与页头让位）
- 如确需微调，`Sources/VoiceOSApp/WorkspaceDesign.swift` 仅可添加阅读排版小原语

## 阅读版面（新文件）
- 文章式版面：笔记标题（短题，大字号，自然换行）、导语（如有）、连续段落；一条共享左边线贯穿标题、小标题、正文（细竖线，颜色取 palette 的弱线色，整列对齐）。边框只留给确有独立边界的内容；不要给笔记套大卡框。
- 元数据轻行：日期、时长、「AI 根据你的口述整理」、回听入口（沿用 playbackAvailable 守卫：audio/video 且 saved），≤meta 字号、次要色，不抢首屏。
- 段落级「看原话」：段落有 anchors 时在段尾放安静的「看原话 N」；展开后就近显示逐字引文，每条引文单独成行并标出处（成员标题+时间），`spanID` 能在成员 `spans` 里解析出 startMS/endMS 时提供「回听这句」；无法精确定位时如实说明可回到哪段来源（成员标题），不得把整理后的第一人称文字放进引号。悬停与键盘聚焦都能揭示该操作。
- 段落的其它操作收进轻量菜单（contextMenu 或 ellipsis）：回听对应段（首锚点）、看原话。
- 状态三态，均不遮挡原文与既有折叠区：
  - generating：「正在整理成笔记…」轻行。
  - unavailable(reason)：如实一句 + 下一步。仅本机保存 → 提供与页头菜单一致的「允许这份文字用于云端并整理」；模型未配置 → 配置文本模型；尚无转写 → 等待转写。
  - failed(message)：原因一句 + 「重试」（`force: true`）。
- 失效：`isCurrent == false` 时笔记上方轻提示「原话已更正或处理许可变化，这篇笔记可能不再对应」+「重新整理」（force:true）；笔记仍可读。
- 无笔记且 idle：轻行「还没有整理成笔记」+「整理成笔记」按钮。
- 短内容：单段笔记按单段安静排版，不加空框、不人为撑高。
- 正文 textSelection(.enabled)；不改主题与底色。

## 接入（WorkspaceSourceView）
- 笔记块作为 readingScrollView LazyVStack 页头之后的第一块，在所有 SourceFold 之前。
- 有当前笔记时页头让位：同一长标题不得两次以大字出现；页头保留操作（回听/更多）与轻量元数据（实现自定）。
- 读取用现有代际键模式：`.task(id:)` 或并入组合读取，键含 `source.id` + `source.transcriptVersionID` + `materialNoteStates[source.id]` + 表达成员版本；结果写回前校验 key（与 `readKeyIsCurrent` 同式），防串写。
- 打开材料时调用一次 `requestMaterialNote(sourceID:)`（幂等）；不重复轰炸。
- 不改 Core；不改 `VoiceOSApp.swift`/`MaterialNoteCenter.swift`；不改首页。

## 约束
- 不跑 swift build/test；改动文件 `xcrun --sdk macosx swiftc -parse` 真实退出码。
- 完成后提交 `work/m169-d`（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：版面结构、页头处理方式、状态矩阵、锚点回听映射、parse 退出码、diff --stat。
