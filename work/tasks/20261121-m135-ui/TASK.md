# 135-B 界面状态、文案与交互评审修复

基准：main 78a8fb1。范围：任务指定的界面文件。`ReflectionTimelineView` 的失败空态实际位于 `ReflectionGraphView.swift`，该文件改了一处调用。未运行 `swift build` / `swift test`，未写实时资料库，未启动应用。

## 逐条结果

1. **空态动作与文案一致。采纳。** `WorkspaceView.unavailable` 增加 `actionTitle` 与可选 `action`，默认仍是「回到行动」并走 `go(.actions)`。材料不可用调用点改为「回到主题」并走 `go(.themes)`，与描述一致。交付、任务两处保持默认。
2. **主题错误随上下文清理。采纳，按来源清理。** 离开主题页时清 `topicFocus` 与 `topicFocusTopicID`。`topicLoadError` 非空时，只清与它匹配的 `error` 和 `errorRetry`，再清 `topicLoadError`。没有无条件抹掉全局 `error`，避免清掉其他操作的失败提示。
3. **重试检索防重入。采纳，token 方案。** `loadSearchHits` 增加 `searchGeneration`，每次进入自增。睡眠后、检索返回后、写结果前都校验 generation。`defer` 只在仍是最新 generation 时清 `searchBusy`。连点或连续改词只有最后一次写结果与失败态，旧任务也不能把 busy 提前清零。未再加按钮 disabled。
4. **搜索建议与应用标题同源。采纳。** 建议行的匹配与标题都用 `displayTitle(source.displayTitle)`，与材料列表同一显示标题。不再用存储名 `displayTitle(source.name)`。现有排序与去重逻辑未动。
5. **WorkspaceEmptyState 支持错误语义。采纳。** 增加可选 `severity` 与 `selectableMessage`。指定 severity 时 description 用对应颜色，`selectableMessage` 打开文本选择。资料库读取失败空态与「暂时无法打开回顾」失败空态改为 `.danger` 且可选中。后者定义在 `ReflectionGraphView.swift`，任务清单里的 `ReflectionTimelineView.swift` 是 `ReflectionEventListView` 的宿主文件。
6. **全景错误与空态的出路。采纳。** 模型拆出 `readError` 与 `readErrorBannerDismissed`。点 x 只置 dismissed，`readError` 与 `.readFailed` 空态保留，「重试读取」继续可点。每次 `refresh` 成功或失败都重置 dismissed，新失败重新弹出横幅，成功即消失。空态 description 在 `toolbarMessage` 非空且不同于 `mode.detail` 时追加第二行，窄窗口丢掉的进度与阻塞信息回到空态。`retryRefresh` 仍走 `refresh(lastStore, lastPort)`，能真正重读。
7. **阅读器原话卡归属。采纳。** 非用户来源恢复「外部 / AI 来源 · 不代表本人认可」。用户原话仍只显示「我的原话」。
8. **标题编辑器预填与列表一致。采纳，带幂等保护。** 存储标题为空或已等于 `record.displayTitle`（手动标题或已收紧）时保留原值，否则用 `MaterialTitleText.normalizedGenerated`，失败回退 `record.displayTitle`。旧原始标题会收紧，已收紧标题与手动标题不会被二次截断。直接套用给定公式会把已收紧标题的尾省略号再剥掉。
9. **子任务 hover 复位。采纳。** 子任务完成圆圈要求 `editable`，子任务删除要求 `!planBusy`，下一步完成圆圈要求 `editable`，才显示 hover 底色。禁用后即使 hoveredID 未复位也不残留底色。
10. **问题列表身份稳定。采纳。** `ForEach` 改用 `enumerated()` 的 offset 作 id。`hoveredQuestion` 与 `@FocusState focusedQuestion` 改为 `Int?`，绑定同一 offset。重复问题字符串不再产生重复 id 或焦点错位。
11. **首页 HomeCard 自带 hover。采纳。** `HomeCard` 内收 `@State hovered` 与 `onHover`，按 `@Environment(\.isEnabled)` 只在可用时显示。删除页面级 `hoveredTimelineID` 与传参，最近想法卡片与时间线行自动同款 hover，父视图不再因 hover 重算。`threadSection` 与 `tasksSummary` 两处手写分隔线换成 `WorkspaceListDivider()`。

## 未采纳/未做

- 未把 `unavailable` 的默认动作改成按页面推断，默认保持「回到行动」。
- 未给检索重试按钮加 disabled，与 token 方案二选一。
- 未改 WorkspaceView 的全局 `workspaceErrorBanner`，它不是 `WorkspaceEmptyState` 调用点。
- 未运行 `swift build` / `swift test`，未写实时资料库，未启动应用。

## 验证

- `xcrun swiftc -parse` 九个改动文件，退出码 0。
- `git diff --check` 退出码 0。
- 逐文件复核 diff，覆盖 11 条。

## 风险

- Panorama 状态机：dismissed 只在 refresh 成功或失败时重置。横幅隐藏后若没有新的 refresh，空态继续显示 `.readFailed` 与重试，这是目标行为。`retryRefresh` 依赖 `lastStore`，全景从未可见时它为空，按钮不会重读；那种情况下通常也没有 readError。
- 空态第二行：`readFailed` 时 `toolbarMessage` 可能仍是旧的进度文案，第二行可能读起来像仍在进行。需要时可只在非 readFailed 模式追加。
- FocusState：offset 作 id 解决了重复字符串，但问题数组重排或增删时焦点会指向新位置，跨刷新不保留焦点。未目视。
- HomeCard：`isEnabled` 来自环境，当前调用点都未禁用。以后在禁用按钮里使用 HomeCard 时会自动抑制 hover。
- 标题预填：幂等保护假设列表标题等于 `record.displayTitle`。若并行单元改了列表标题来源但未同步 `displayTitle`，预填可能与列表不同。
- 未构建、未运行，所有视觉与焦点行为需主会话集成构建后目视确认。