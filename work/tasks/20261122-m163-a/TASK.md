# 163-A 材料页组合读取的子键门控（WorkspaceSourceView.swift）

## 背景（评审 CONFIRMED）
162-A 把 8 个读取合并为单一 `.task(id: combinedReadKey)`，但 key 取并集：任一子输入变化（讨论列表、thoughts 数、政策版本等）都会重启全部读取，并先清空 attachment/entities/chapters/context 等无关状态 → 附件按钮消失、章节/实体每次重读（含整段 NLTagger 与媒体解析）、上下文闪烁。修复：保留单任务结构，但在任务内按 helper 的**自身子键**做 last-applied 门控；子键未变时跳过该 helper（不清状态、不读取）。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceSourceView.swift

## 改动
1. 保留 `SourcePageReadKey` 与组合 `.task(id:)`；新增 `@State private var appliedReadKeys: [String: String] = [:]`（或等价结构），每个 helper 用自己的稳定子键字符串：
   - attachment：来源 id + 附件相关版本（沿用原 `source.id` 任务实际依赖；若仅 source.id，则键=sourceID）。
   - claimNotes：sourceID。
   - pause：原 pauseReadKey 的等价字符串。
   - discussions：原 discussionReadKey。
   - context：原 contextReadKey。
   - entities：原 SourceTranscriptReadKey。
   - chapters：原 SourceChapterReadKey。
   - extraction：原 extractionFlagRefreshKey。
2. 每个 helper 入口：`guard appliedReadKeys[helper] != subKeyString else { return }`；通过后先写 applied 键再执行读取；失败路径保持原错误状态（applied 写在前或后需保证失败后重试仍会触发——在读取前写入，失败重试由用户重试 token 改变子键）。
3. 子键未变时不得清空任何 @State（attachmentURL、chapters、entities、programPairs 等清空语句必须移入 helper 的门控之后）。
4. 保留 162 的防串写校验（key 与取消）不变。
5. 行为：同一子键的无关组合键变化不再引起任何该 helper 的读取或状态清空；相关变化仍照常读取。

## 约束
- 只改这一个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、8 个 helper 的子键定义、清空语句迁移位置、防串写保留方式、parse 退出码、diff --stat。