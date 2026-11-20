# 波 111-A：材料详情页失败可恢复性与转写等待三态

## 背景

材料详情页四个分节与原文版本读取失败时只显示黄色文字，用户没有恢复路径。转写未完成时，排队、转写中、失败三种情况共用一句「尚未完成转写 · 原件已保存」，用户无法判断该等待还是该重试。本单元只改 `Sources/VoiceOSApp/WorkspaceSourceView.swift`。行号同时标注基线（fa18612）与改动后位置。

## 逐条修法

### 1 分节失败可重试

- 基线：`SourceLoadFailureText` :144-149；调用点 :849（节目关联）、:861（章节）、:868（人名与术语）、:905（讨论）。
- 修法：类型改名为 `SourceLoadFailureRow`（改动后 :148-164）。文案由 `InlineFailurePresentation.message(operation:reason:)` 生成，即「操作 + 失败 + 原因」口径，原因超过 60 字截断。行尾加「重试」按钮。
- 重试机制：四个 phase 各加一个 `@State` 计数器（`contextRetry`、`discussionsRetry`、`entitiesRetry`、`chaptersRetry`），计入对应 `.task(id:)` 的 key（改动后 :306、:1069、:1087、:1136）。计数变化时 SwiftUI 取消旧任务并重启加载函数；任务起步即把 phase 置 `.loading` 并清空对应数据，所以既有 `SourceLoadingRow` 在重试期间显示，每个 phase 同一时刻只有一个 in-flight 任务。
- 重试闭包：改动后 :883、:895、:902、:939。
- 数据保留策略不变：章节与人名的失败行只在列表为空时显示；节目关联失败行可与已加载的节目对同时出现。

### 2 原文版本失败可重试

- 基线：:350 的 `WorkspaceNoticeText`；既有 `loadHistory()` 在 :368-381。
- 修法：失败分支改为 `SourceLoadFailureRow(operation:"读取原文版本",reason:message,retry:loadHistory)`（改动后 :377）。`loadHistory()` 自身先取消 `historyTask` 再起新任务，重试不会叠加旧任务。

### 3 转写等待三态

- 证据：`SourceRecord.jobState` 定义在 `Sources/VoiceOSCore/Models.swift:30`；转写任务写入的状态见 `Sources/VoiceOSCore/Store.swift:339`（queued）、:356（running）、:390（completed）、:395（failed）、:372（blocked，空转写）。
- 修法：新增 `transcriptionRunning`（jobState 为 queued 或 running，改动后 :362）与 `transcriptionFailed`（failed 或 blocked，改动后 :365），两者都要求 transcript 为空。
- 状态行（基线 :331-340 与 :645；改动后 :350-356、:672-678）：转写中显示 spinner 加「正在转写…」；失败显示警告色「转写失败 · 原件已保存」；其余状态保持原文案「尚未完成转写 · 原件已保存」。
- 原文折叠内占位（基线 :1119；改动后 :1152-1159）：转写中显示 spinner 加「正在转写… 原件已保存」，失败显示警告文案，其余保持「尚无可用转写 · 状态」。
- 取舍：blocked 归入失败态，与基线 :714 对 failed 和 blocked 一并显示「重试本地转写」一致。cancelled、unknown、completed 但无文字等模型未明确的状态沿用原文案，不臆造。

### 4 卡片内边距收敛

- 基线 :112（22）、:160（18）、:201（22）、:219（14）、:656、:681、:696（16）、:720（20）。
- 修法：:112、:160、:201、:720 去掉显式覆盖，回到默认 20（改动后 :116、:174、:215、:754）。:219 的跟进卡由 14 调为紧凑 16（改动后 :233）。三张提示卡保持 16（改动后 :690、:715、:730）。圆角、结构与 identifier 未动。

## 构建与测试

按任务给定的共享锁门执行，工作目录为本工作树，真实退出码如下。

- `swift build -j 2`，`build_exit=0`
- `swift test -j 2`，`test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 48.424 (48.492) seconds`

本轮一次拿到共享锁，未出现超时。

## 未做与风险

- 未新增视图测试：包内没有覆盖 SwiftUI 视图的测试目标，任务限定只改一个源码文件。
- 未实机验证：任务禁止重启应用，转写中 spinner 与失败行重试只过了编译与单元测试，没有截图证据。
- 失败原因现在按 `InlineFailurePresentation` 截断到 60 字。讨论读取失败的完整文本仍会写入 `error` 并在处理记录底部显示，其余三处只保留截断后的单行。这是统一口径的代价，完整原因是否保留留给后续波次决定。
- 重试只在失败态出现，失败行不提供取消。phase 的并发上限由 `.task(id:)` 的取消语义保证，不是显式锁。
- 跟进卡内边距从 14 变为 16，属于轻微观感变化。

## 约束

只改 `Sources/VoiceOSApp/WorkspaceSourceView.swift`；未写 `~/Library/Application Support/VoiceOS`；未重启应用；未 push、未合并。