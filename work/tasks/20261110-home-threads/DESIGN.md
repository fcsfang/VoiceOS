# 首页线索式阅读：实现契约

视觉与信息结构以 `/tmp/voiceos-home-v2-proto/index.html` 的 A 变体为准，数据用真实 11 月 8 日录音（79 条想法、1 小时 41 分）。本文件是代码契约。

## 数据形状（`Sources/VoiceOSCore/RecentContent.swift`）

```swift
public enum RecentThoughtKind: String, Codable, Sendable { case insight, goal, note }

public struct RecentContentThought: Identifiable, Equatable, Sendable {
    public let claimID: String
    public let statement: String
    public let kind: RecentThoughtKind
    public var id: String { claimID }
    public init(claimID: String, statement: String, kind: RecentThoughtKind = .note)
}

public struct RecentContentThread: Identifiable, Equatable, Sendable {
    public let id: String          // family | work | career | self | life
    public let title: String
    public let thoughts: [RecentContentThought]
    public let lead: RecentContentThought?
    public let supporting: [RecentContentThought]   // 最多 2
    public let goals: [RecentContentThought]        // 全部目标，视图只展示前 2
    public var remaining: [RecentContentThought] { get } // 除 lead / supporting / goals.prefix(2) 之外
    public var hiddenCount: Int { remaining.count }
}

public struct RecentContentTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
}

public struct RecentContentDigest: Equatable, Sendable {
    public let threads: [RecentContentThread]
    public let tasks: [RecentContentTask]
    public let duration: TimeInterval
    public let thoughtCount: Int
    public static func build(thoughts: [RecentContentThought], duration: TimeInterval, tasks: [RecentContentTask] = []) -> RecentContentDigest
    public static func threadID(for statement: String) -> String
    public static func threadTitle(_ id: String) -> String
    public static func leadScore(_ statement: String) -> Double
    public static func orderedTasks(_ tasks: [RecentContentTask]) -> [RecentContentTask]
    public static func durationLabel(_ duration: TimeInterval) -> String
}
```

`RecentContentItem` 增加 `duration: TimeInterval`（来源 `source.duration ?? 0`，反馈组为 0），初始化器给默认值 0，保持现有调用可编译。`RecentContentIndex.build` 用解析结果填 `RecentContentThought.kind`；`thoughtStatement` 保留现有行为并加前缀剥离。解析规则：

- 去掉「说明：」及其后内容，去尾部标点。
- 前缀 `【观点】` 为 insight，`【长期目标】` 为 goal，无前缀为 note。
- 以 `【录音中活动】` 开头、以 `（待核对）`/`(待核对)` 结尾、或以 `说明：` 开头的整条丢弃。
- 去重按清洗后的 statement。

线索规则（先家人，再生活信号，再实习与交付、职业与学习、对自己的认识，其余生活杂记）：

- family：父、母、家人、爸、妈、亲戚、交流、长谈
- life 信号：播客、录制、视频、游戏、短视频、耳机、AirPods、网易云、结婚、作息、提醒事项、助听
- work：实习、领导、项目、汇报、交付、完美、闭门、同事、成果、打磨、展示、任务
- career：AI、GPT、代码、技术、职业、工程师、学习、简历、开题、答辩、决策、能力
- self：自信、自卑、悲观、勇敢、改变、藏锋、犯错、思考、自我、探索、值得、价值、逃避、谦虚
- 展示顺序：家人、实习与交付、职业与学习、对自己的认识、生活杂记；空线索不展示。

主引用评分（越大越优先，只在 `.insight` 中选；没有 insight 时在非 goal 中选）：

- 反思词每个 +3：认为、觉得、应该、不应、不必、意识、发现、长期、过去、改变、学习、值得、重要、可能、包容、自信、自卑、勇气、完美、交付、汇报、沟通、思考、逃避、价值、成长、更好、真正
- 具体词每个 -4：项目是、功能、AirPods、网易云、耳机、第一个、第二个、今天、明天、下周、上周、提醒事项、PPT、答辩
- 长度加成 `min(字符数, 40) / 10`

支撑想法：其余 insight 中评分最高的两条。目标块：该线索全部 goal 的前两条。`remaining` 不得包含 lead、supporting、前两条 goal，且并集必须覆盖线索全部想法。

任务排序：标题含今天、明天、后天、下周、周一至周五、周末、今晚的排在前面，其余保持传入顺序；视图取前 4 条。

时长：0 返回空串；小于 60 秒返回「不到 1 分钟」；否则「N 分钟」或「N 小时 M 分」。

## 视图（`Sources/VoiceOSApp/RecentContentHome.swift`）

保留左栏 + 右栏。左栏行对材料显示 `时:分 · N 条想法 · M 条线索`（M 用该 item 的 digest），反馈组保持现状。右栏：

- 元信息：`11月8日 · 22:48 · 1 小时 41 分 · 79 条想法`（用 `RecentContentDigest.durationLabel`）。
- 标题：`system(size: 27, weight: .semibold, design: .serif)`，行距 4。
- 导语：`这次录了 1 小时 41 分，留下 79 条想法，可以归成 5 条线索。` 14.5 号、次要色、行距 5。
- 线索索引：横向五个按钮，标题 + 计数；点击用 `ScrollViewReader` 滚到对应线索，带轻微动画。
- 每条线索：顶部 1 像素分隔线；编号（13 号衬线、强调色、宽 28）+ 标题（15.5 号半粗）+ 右侧计数（11 号次要）；引用块左侧 2 像素强调色竖线，文字 19 号衬线、行距 7、左缩进 42、内缩进 16；支撑想法 14.5 号、行距 5、左缩进 42；目标块浅色底（`palette.selection.opacity(0.6)`，9 圆角，内边距 13×17），小标签「想慢慢做到」10 号、字距 1.4、强调色，目标 14 号；「展开这一线索的 N 条」12.5 号强调色，展开后在原地列出 remaining（每行小标签 观点/目标/想法 + 13.5 号陈述），再给「收起」。
- 「接下来」：小标签 + 最多 4 条任务，圆圈描边 + 标题 14.5 + 「来自这次录音 · 待办」11 号次要；超过 4 条给「全部 N 条」/「收起」。
- 「录音概览（AI 整理）」：`DisclosureGroup`，默认折叠，正文 13.5 号次要色。
- 底部「打开材料」文字按钮，强调色。
- 所有颜色用 `workspacePalette`；不写死米色。标题与引用用 serif，其他用系统字体。
- 切换材料时重置展开线索与任务展开状态；切换时滚动回顶部。
- 保留 `accessibilityIdentifier("recent.item")`，新增 `home.thread`、`home.thread.expand`、`home.task`。

`RecentContentHome` 的初始化签名不变；任务从 `model.actionRecords` 过滤 `state == "open"`、`validity == "current"`、`kind == "task"`、`claimID` 在该 item 的 thoughts 中，生成 `RecentContentTask`，按 `orderedTasks` 排序。

## 测试（`Tests/VoiceOSCoreTests/RecentContentDigestChecks.swift`）

纯函数测试，不碰实时库：

- 前缀解析为 insight/goal/note，说明与待核对被去掉。
- 每条想法恰好落进一条线索；五条线索计数和等于输入数。
- 主引用选反思而非事实：「完成比完美更重要」压过「第二个实习项目是……」；「过去对父亲的了解有偏差」是家人线索主引用。
- 生活信号优先：AirPods 与录制目标落在生活杂记；「写下交流收获」落在家人。
- 支撑、目标、remaining 无重叠且并集覆盖全部；hiddenCount 正确。
- 任务排序把含「下周一」「周四」的标题排在前面，且保持其余相对顺序。
- 时长格式化。

## 不做

不新增模型调用、不改提取提示词、不做线索重命名/合并、不改左栏以外的页面。
