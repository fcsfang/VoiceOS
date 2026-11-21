# 149-A 首页行呈现单次计算与静态日期格式器（RecentContentHome）

## 背景
性能发现：首页每个可见行在每次渲染时分配 1-2 个 DateFormatter，并把标题拟合（WorkspaceTitleFit.present）跑 2-3 次（rowTitle、rowMeta、rowAccessibilityLabel 各一次）；整个时间线在任意 ControlCenter 发布时重算。本单元做纯计算侧收敛，不改视觉与交互。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/RecentContentHome.swift

## 改动
1. **静态格式器**：参照 WorkspaceView.swift:65-78 的 `MaterialDayFormatting` 模式，在 RecentContentHome.swift 加文件私有 `enum HomeDateFormatting`：`time`（HH:mm）、`dayCurrentYear`（M月d日）、`dayOtherYear`（yyyy年M月d日），locale zh_CN。`timeLabel(_:)`、`dayLabel(_:)` 改用静态实例（今天/昨天判断保持原样）。
2. **行呈现单次计算**：新增
   ```swift
   private struct HomeRowPresentation {
       let title: String
       let meta: String
       let trailing: String?
       let accessibilityLabel: String
       let icon: String
   }
   private func rowPresentation(_ item: RecentContentItem) -> HomeRowPresentation
   ```
   内部只调用一次 `WorkspaceTitleFit.present(item.title)`，复用其结果生成 title/meta；accessibilityLabel 基于同一结果拼装（保持原分隔符与顺序："，" 连接、meta 用 " · "）；icon 逻辑照旧。
   `row(_:)`、`rowAccessibilityLabel`、`rowMeta`、`rowTitle`、`rowIcon` 改为消费该呈现（可保留旧函数为其薄包装，但每次渲染路径只计算一次 presentation；同一行内不得重复计算）。
3. 行为必须逐字一致：标题、元数据、无障碍朗读文本、图标、颜色与布局不得变化。

## 约束
- 不改视觉、交互与业务；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后在本工作树提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、presentation 被哪些行路径复用、format 静态化位置、parse 退出码、diff --stat。