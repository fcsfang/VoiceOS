# 波 97 任务 B：主题列表加查找入口

## 背景

真实库有 93 个主题，91 个在近 7 天更新过。主题列表页只有一面 LazyVGrid 卡片墙，没有搜索或筛选，用户只能滚动找主题。材料页早有筛选标签，主题页没有。

## 改动

- `Sources/VoiceOSApp/WorkspaceView.swift:323` 新增 `@State private var topicQuery = ""`。
- `Sources/VoiceOSApp/WorkspaceView.swift:1018-1021` 主题列表分支计算过滤词与 `visibleTopics`。过滤对已发布的 `model.workspaceTopics` 本地执行，匹配标题与 `organization?.summary`，用 `localizedCaseInsensitiveContains` 做大小写不敏感子串匹配；清空输入即恢复全部。
- `Sources/VoiceOSApp/WorkspaceView.swift:1025-1026` 网格上方插入 `WorkspaceSearchField`，占位文案「搜索主题标题或摘要」，`accessibilityIdentifier("topics.search")`。
- `Sources/VoiceOSApp/WorkspaceView.swift:1027-1033` LazyVGrid 改为渲染 `visibleTopics`，惰性容器、列布局与点击行为不变。
- `Sources/VoiceOSApp/WorkspaceView.swift:1034` 有过滤词且结果为空时显示一行「没有匹配的主题」。
- `Sources/VoiceOSApp/WorkspaceView.swift:1035` 无过滤词的空态保持原文案，只在 `filter.isEmpty` 时显示。

## 验证（真实退出码）

- `swift build -j 2; echo build_exit=$?` → `build_exit=0`（Build complete，121.72s）。
- `swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 645 tests, with 0 failures (0 unexpected) in 57.404 seconds`。基线 645，本次未加测试，计数不变。
- 构建与测试都在 `/tmp/voiceos-swift-build.lock` 互斥锁内执行（与并发的 m97-panorama 波共用同一把锁），结束时解锁。

## 取舍与遗留风险

- `topicQuery` 状态在 `:323`，位于任务书给出的约 1000-1059 区段之外，但仍在同一文件。SwiftUI 的 `@State` 只能挂在 View 结构体上，放在既有主题状态旁边是唯一自然位置。主题区段内的改动都在 1017-1035。
- 过滤只覆盖标题与摘要，不含小主题正文与原话，符合任务书「按标题与摘要」的范围。
- 匹配把整个过滤词当作一个子串（去首尾空白），与材料页、知识页的 `localizedCaseInsensitiveContains` 用法一致，没有拆词。多词查询按连续子串匹配。
- 网格下方的「尚未归入主题的材料」区块不参与过滤，行为未改，符合「不改其他区块」。
- 过滤词在进入主题详情再返回列表后保留，没有在「所有主题」按钮里清空。保留的好处是回到列表还能接着看同一批结果；若产品希望返回即重置，需要再改一行。
- 未重启应用，未做真实 GUI 操作验证。改动是纯视图层过滤，在本地数组上执行，构建与全量测试通过；肉眼效果留给父级合并后的下一次重启检查。
- 未加迁移，未改 schema；未 push，未合并 main。