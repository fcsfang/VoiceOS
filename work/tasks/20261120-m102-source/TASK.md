# 波 102-B：材料详情页视觉统一

## 背景

材料详情页此前混用了三套容器语言（22pt 内边距的半卡、selection 底色的 12pt 面板、系统默认按钮），URL 材料直接把裸链接当 30pt 标题，计数以「标题 + 小字数字」散落展示。本波把页面收敛到波 101 引入的共享词汇：WorkspacePageHeading 的页头结构、WorkspaceCard、WorkspaceBadge、WorkspaceSectionHeading 与 workspacePrimary/Secondary/Quiet/SecondaryCompact 按钮。只改 `Sources/VoiceOSApp/WorkspaceSourceView.swift`，数据逻辑、accessibilityIdentifier、折叠默认值与锚点 id 全部保持。

## 改动

1. `Sources/VoiceOSApp/WorkspaceSourceView.swift:103-132` — `SourceFold` 改用 `WorkspaceCard(padding:22)`；计数从标题旁的小字改为 chevron 左侧的 `WorkspaceBadge(.neutral)`。`source-original-fold` 锚点与展开状态不变。
2. `WorkspaceSourceView.swift:150-192` — `UnresolvedIssuesBlock` 自身成为 `WorkspaceCard(padding:18)`；「回听 / 跳到原文」改 `.workspaceQuietCompact`。两处调用（页面顶部与处理记录内）都去掉外层 selection 底色。
3. `WorkspaceSourceView.swift:193-211` — 新增文件内 `SourceSection`：`WorkspaceCard(padding:22)` + `WorkspaceSectionHeading(title:count:)` + 发丝线，替代旧 `WorkspaceSection` 的胶囊计数。
4. `WorkspaceSourceView.swift:212-240` — 新增 `SourceFollowupCard`：`WorkspaceCard(padding:14)`，用 `WorkspaceBadge` 展示「旧思想关联 N」「目标下一步 N」（英语练习时追加 accent 徽标），右侧 `.workspaceQuietCompact`「查看思想与下一步」。
5. `WorkspaceSourceView.swift:565-568` — `readingTitle` 不再预剥 `#`，交给 `WorkspaceTitleFit` 统一处理；多段表达仍用分组标题。
6. `WorkspaceSourceView.swift:569-616` — 页头动作：「回听 / 开始按天读」改 `.workspaceSecondaryCompact`；「更多」菜单改 `.menuStyle(.button)` + `.workspaceSecondaryCompact`，整行间距 8，删除 `.controlSize(.small)`。
7. `WorkspaceSourceView.swift:619-653` — 页头改为元信息行（meta/secondary）→ `WorkspaceTitleFit.present(readingTitle)` 的标题 → 可选来源行（caption/tertiary，可选中文本）。状态行改 caption/secondary，并新增 `WorkspaceBadge("转写疑点 N", .warning)`；「查看原件 / 查看原图」改 quiet compact。
8. `WorkspaceSourceView.swift:494-542` — 观点行：正文与动作间距 8；「记录行动意图」改 `.workspaceSecondaryCompact`，与 ⋯ 菜单同一行右侧；「原话依据、旁注与调整」改为 caption/secondary 的自定义 label；「回听这段原话 / 审阅历史 / 查看原讨论」改 quiet compact。
9. `WorkspaceSourceView.swift:654-707` — 空提取提示、连续表达分组不可用、纠错影响三块改 `WorkspaceCard(padding:16)`；主重做动作 secondary compact，确认类动作 quiet compact。
10. `WorkspaceSourceView.swift:714` — 「重试本地转写」由 `.borderedProminent` 改 `.workspacePrimary`。
11. `WorkspaceSourceView.swift:718-752` — 暂停面板由 selection 半卡改 `WorkspaceCard(padding:20)`；「允许云端并重新识别」「重新识别观点和任务」改 `.workspacePrimary`，配置模型改 quiet compact。
12. `WorkspaceSourceView.swift:759-761` — 页内跟进块改用 `SourceFollowupCard`（见第 4 条）。
13. `WorkspaceSourceView.swift:763/774/779/786/821/885` — 六处 `WorkspaceSection` 改为 `SourceSection`，计数走 `WorkspaceSectionHeading` 的 tertiary 数字。
14. `WorkspaceSourceView.swift:454/526/531/537/549/555/799/834/837/897/899/905/934/936` — 折叠内动作按主次收敛为 `.workspaceQuietCompact` / `.workspaceSecondaryCompact` / `.workspaceQuiet`。
15. `WorkspaceSourceView.swift:1566-1569/1611-1614/1650-1653` — 三个 sheet（更正原文、更正理解、分组标题）的「取消」改 secondary，「保存/更新」改 primary，「恢复自动标题」改 quiet。
16. 全文件不再出现 `WorkspaceMetrics.panelRadius` 或 9/20 圆角；内容卡只剩 `WorkspaceCard` 的 sectionRadius（16），控件圆角保持 controlRadius（8）。

## 验证

真实退出码，构建与测试均在 `/tmp/voiceos-swift-build.lock` 互斥锁内执行，管道后不接命令：

- `swift build -j 2` → `build_exit=0`，`Build complete! (128.29s)`（283 步）
- `swift test -j 2` → `test_exit=0`，`Executed 661 tests, with 0 failures (0 unexpected)`（另有一行 4 tests 的嵌套执行摘要，均为 0 失败）

未启动或重启应用（本波约束），因此没有截图或实机目视验证；页头与卡片的视觉结果仅由代码结构确认。

## 取舍与风险

- 「旧思想关联 1 · 目标下一步 1」原实现是 `RecordingFollowupView.swift` 里的 `RecordingFollowupSummary`，不在本波允许修改的文件内。为守住单文件约束，本文件新增了 `SourceFollowupCard`，读取同一 `RecordingFollowupReceipt` 与 `followupValidity`，行为一致；代价是同一回执在跟进页与材料页有两套展示，后续应由拥有 `RecordingFollowupView.swift` 的波次把共享组件升级为同一张卡并删除本地副本。
- 标题按 `WorkspaceTitleFit.present(readingTitle)` 计算而非字面 `source.displayTitle`，以保留多段连续表达的分组标题；单段材料的结果与诉求一致，URL 的裸链接会被拆成末段标题 + 来源行。
- 「更多」菜单依赖 `.menuStyle(.button)` 承接自定义 `ButtonStyle`；若该 macOS 版本不传递样式，只会退回系统菜单外观，不改变行为。未做实机确认。
- 六处 `WorkspaceSection` 改 `SourceSection` 后不再显示章节图标（checkmark.circle、lightbulb、waveform、quote.bubble），这是为对齐 `WorkspaceSectionHeading` 而做的有意删减；如需保留图标应扩展共享组件而不是本文件。
- `UnresolvedIssuesBlock` 现在是卡片，在「处理记录」折叠内会形成嵌套卡片（双层发丝线）；视觉可接受，但若嫌重可在后续波次给该组件加 `carded` 参数。
- 未改动任何数据读取、任务状态、折叠默认值、accessibilityIdentifier、`source-original-fold` / `source-para-*` / `source-span-*` 锚点。