# 波 115-B 反思、阅读与练习页面的计数与时间码改用等宽数字

基线 `work/m115-b`，工作树 `.worktrees/m115-b`。只改以下八个文件：

`ReflectionTimelineView.swift`、`IncrementalReadingView.swift`、`FeynmanPractice.swift`、`ReflectionChangeView.swift`、`OutcomeFollowupView.swift`、`EnglishPracticeView.swift`、`TextCaptureView.swift`、`WorkspaceTopicReadingView.swift`。

## 目标

按排版审计，反思、阅读、练习类页面的计数与时间码使用比例数字，位数变化时文本宽度跳动。给这些数字补等宽，日期时间戳不加。`vosFont(WorkspaceTextStyle)` 重载不接收 `monospacedDigit`，因此带该参数的调用写成 `vosFont(style.size, ...)` 形式，权重按原 style 补 `weight:`，与 `TextCaptureView.swift:129` 的既有写法一致。标识符、文案语义、布局与字号档位均未改。

## 逐处改动（原值 → 新值）

1. `ReflectionTimelineView.swift:80` 计数行 `.vosFont(WorkspaceText.caption)` → `.vosFont(WorkspaceText.caption.size, monospacedDigit: true)`。文案「n 条表达 · n 条结果与反思 · n 条完成登记」未动。
2. `IncrementalReadingView.swift:30` 分块计数 `.vosFont(WorkspaceText.meta)` → `.vosFont(WorkspaceText.meta.size, monospacedDigit: true)`。文案「第 x/y 块 · 每块约 n 字」未动。
3. `FeynmanPractice.swift:29` 复述字数 `.vosFont(WorkspaceText.caption)` → `.vosFont(WorkspaceText.caption.size, monospacedDigit: true)`。
4. `ReflectionChangeView.swift:62` 关联候选计数 `.vosFont(WorkspaceText.caption)` → `.vosFont(WorkspaceText.caption.size, monospacedDigit: true)`。
5. `OutcomeFollowupView.swift:19` 待记录项计数 `.vosFont(WorkspaceText.caption)` → `.vosFont(WorkspaceText.caption.size, monospacedDigit: true)`。
6. `EnglishPracticeView.swift:100` 「反馈历史（n）」`.vosFont(WorkspaceText.rowTitle)` → `.vosFont(WorkspaceText.rowTitle.size, weight: .semibold, monospacedDigit: true)`。`rowTitle` 的权重是 semibold，显式保留。
7. `TextCaptureView.swift:129` 字数统计核对后已是 `.vosFont(WorkspaceText.caption.size, monospacedDigit: true)`，无需改。`:57` 草稿自动保存提示 `.vosFont(WorkspaceText.caption)` → `.vosFont(WorkspaceText.meta)`，与同页 `:61` 的 meta 层级一致。
8. `WorkspaceTopicReadingView.swift:69` 「n / n 个小主题」`.vosFont(WorkspaceText.meta)` → `.vosFont(WorkspaceText.meta.size, monospacedDigit: true)`。

## 验证

共享锁循环，工作目录 `.worktrees/m115-b`，`swift build -j 2` 与 `swift test -j 2`，一次通过。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 44.304 (44.363) seconds`

## 未做与取舍

- 未重启应用、未截图核对视觉。约束是不重启应用，验证止于全量构建与测试。
- `TextCaptureView.swift:102` 模板替换弹窗里的 `\(draft.text.count) 字` 属于 alert 确认文案，不是页面计数行，未加等宽。
- 其他页面同类计数的全量清扫留给后续波次，本轮不扩围到八个文件之外。
- 未 push、未合并。