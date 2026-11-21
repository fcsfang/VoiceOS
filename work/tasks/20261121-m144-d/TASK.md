# 144-D 讨论页自动跟随与周回顾撤销条（WorkspaceDiscussionView / WeeklyReviewView）

## 背景
动效发现两处：讨论页刷新驱动的视口移动有三种时长，且自动跟随可能在用户翻看上文或输入时把视口拽走；周回顾撤销条的过渡是唯一没有 reduceMotion 门控的。本单元使用 144-B 在 WorkspaceDesign 定义的 `WorkspaceMotion` 词表（`scroll` 0.18 easeOut、`transient` 0.2 easeOut），本工作树暂时没有该定义属预期，按契约引用。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/WorkspaceDiscussionView.swift
- Sources/VoiceOSApp/WeeklyReviewView.swift

## 逐条

### 1. 讨论页视口跟随即时性与时机
- 约 122 行区域：grep 本文件所有 `scrollTo(` 与 `withAnimation`。把刷新后「跟随最新消息」的滚动统一为 `withAnimation(reduceMotion ? nil : WorkspaceMotion.scroll) { proxy.scrollTo(底部锚点) }`，同类跳转用同一词表。
- 自动跟随护栏：当用户正在输入（输入框 focused）或用户已经手动向上翻阅（当前视口不在底部附近）时，刷新到达不要自动滚动。若文件已有等价状态（如 `scrollFollow`/`isAtBottom`/`composerFocused`）就复用；没有则加最小状态：记录最后一次用户滚动后的可见锚点/底部距离，或简单地在 composer focused 时暂停跟随。目标：刷新永不把正在阅读或正在输入的视口拽走；用户发送消息后仍滚到最新。
- 不改消息渲染、发送与业务逻辑。

### 2. 周回顾撤销条 reduceMotion
- 约 427 行 `if undoEntry != nil` 区域的过渡：给撤销条加上与 toast 一致的进出（`withAnimation(reduceMotion ? nil : WorkspaceMotion.transient)` 驱动 `undoEntry` 的置位/清除），确保 `.transition(...)` 在 reduceMotion 下等效静止。现有 8 秒自动清除逻辑不动。
- 同文件其它手写 `easeOut(duration:` 若属展开/收起或临时浮层，分别换 `WorkspaceMotion.expand` / `WorkspaceMotion.transient`（reduceMotion 门控保留）。

## 约束
- 只改动画/滚动时机与跟随护栏，不改文案、业务与布局。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、逐条完成情况、跟随护栏采用的状态与判断、parse 退出码、diff --stat。