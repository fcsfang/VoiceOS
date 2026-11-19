# 波 102-E：主题页与思想全景页视觉统一

分支 `work/m102-topics`，基线 `529b9d4`（共享按钮、徽标、页头、卡片组件）。

## 背景

用户目标是让主题页与思想全景页读起来像精心设计过的界面。上一波已加入
`WorkspaceButtonStyle` 三档按钮、`WorkspaceBadge`、`WorkspacePageHeading`、
`WorkspaceSectionHeading`、`WorkspaceCard`，本波只在两个页面里收编旧样式：
行为、空状态判定、panorama 生成流程与数据一律不动，不新增颜色与字号。

改动仅限两个文件：
- `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift`

## 改动逐条

### WorkspaceTopicReadingView.swift

- L124 概览里的结构折叠标签改为 `WorkspaceSectionHeading` 语义的 HStack，
  小主题数从标题里拆出，放进 `WorkspaceBadge(.neutral)`。
- L148 `introduction` 由手写 surface 容器改为 `WorkspaceCard`（padding 20、
  圆角 16、hairline）。
- L168 `topicPendingBanner` 改为 `WorkspaceNoticeText(severity:.info)` 加
  `补齐正文` 次按钮（`.workspaceSecondaryCompact`）；`bodyPending` 判定不变。
- L176 `preparingCards` 改为 `WorkspaceCard`；`补齐正文` / `整理主题卡片`
  是这张卡唯一主操作（`.workspacePrimary`），`配置文本模型…` 为
  `.workspaceQuietCompact`。
- L205 `structure` 改为 `WorkspaceCard`；页头换 `WorkspaceSectionHeading`，
  `查看全部` 为 `.workspaceQuietCompact`；当前主题卡圆角统一 16 并补 hairline；
  `展开全部…` / `收起结构` 为 `.workspaceQuietCompact`。键盘焦点、方向键与
  Return 处理、`onChange`/`onAppear` 原样保留。
- L267 `查看全部 N 张卡片` 由 `.bordered` 改为 `.workspaceSecondary`。
- L272 `readingCard` 改为 `WorkspaceCard`（20、16、hairline），去掉旧的
  canvas 底色与左上 3px 行动色条；`相关观点`、`相关行动与问题` 的数字移入
  `WorkspaceBadge`；更正/停止使用、来源按钮、讨论按钮统一为
  `.workspaceQuietCompact`。
- L361 问题行保留 hover 切换，容器改为 16 圆角加 hairline，与卡片同构。
- L397/L400/L456/L491/L494 关联来源、个人记录、结果记录内的文字按钮统一为
  `.workspaceQuietCompact`。
- L537 `TopicStaleBanner` 改为 `WorkspaceNoticeText(severity:.info)`，文案不变。
- L543 `WorkspaceTopicTile` 改为 `WorkspaceCard`，hover 由底色切换改为 accent
  hairline；`正文整理中` 改用 `WorkspaceBadge`；箭头字体改用
  `WorkspaceText.caption` 令牌。

### ThoughtPanoramaView.swift

- L39 页头新增 `WorkspacePageHeading(title: "思考全景")`，放在工具栏上方；
  toolbar 内原来的同名 Text 删除，避免重复。
- L286 `readErrorBanner` 改为 `WorkspaceNoticeText(severity:.danger)` 加
  `.workspaceSecondaryCompact` 重试与 `WorkspaceIconButton` 关闭。
- L296 `partialChip` 改为 `WorkspaceBadge(tone:.warning)`，仍是打开覆盖面板的
  按钮，help 与 accessibilityLabel 不变。
- L410-430 `contextualControl`：连接文本模型、生成综合草稿为
  `.workspacePrimary`；继续核对按草稿是否可用二选一（L428），保证一屏一个
  主操作。
- L510-516 候选联系行状态改为 `WorkspaceBadge("尚待核对", .warning)`。
- L641 `emptyState`：空状态文案与 `PanoramaEmptyMode` 判定未动；打开材料与
  重试/继续核对按能否重试分配主次（L655）。
- L674 新增 `coverageBadge(for:snapshot:)`；L680 覆盖面板的来源状态改为
  徽标（尚未核对 / 已核对并表达 / 已核对，未归入具体问题），面板按钮统一
  `.workspaceQuietCompact`。
- L841 `在主题中查看` 改为 `.workspacePrimary`，去掉内边距让样式接管。
- L948 `themeQuoteCard`、L1160 `ReaderQuoteCard` 改为 `WorkspaceCard(padding: 12)`；
  引用卡按钮统一 `.workspaceQuietCompact`。
- L1081 候选联系解释的状态文案改为 `WorkspaceBadge(tone:.warning)`。
- L1214 `ReaderPrimaryAction` 改为 `.workspacePrimary`。
- L1235 `ReaderDisclosure` 增加 `count` 参数并在标题后渲染徽标；调用点
  L890/L900/L1019/L1148 同步，数字不再黏进标题。
- L1307 摘要展开按钮、证据块问题链接、AI 回应重试统一 `.workspaceQuietCompact`。
- L1328 `ReaderQuestionRow` 的原话计数改为徽标；问题检查器的原话计数同理。
- 删除 ReaderQuoteCard / ReaderEvidenceBlock / ReaderCappedText 中不再使用的
  palette 环境依赖。`PanoramaConstellationView` 的绘制逻辑与外围容器未动。

## 验证

- 构建：`swift build -j 2`（共享锁 `/tmp/voiceos-swift-build.lock` 串行），
  `build_exit=0`，日志 `/tmp/m102-topics-build.log`。
- 测试：`swift test -j 2`（同一把锁），`test_exit=0`；661 个测试，0 失败，
  日志 `/tmp/m102-topics-test.log`。测试命令在后台完成，真实退出码取自输出
  文件的 `test_exit=0`，不是包装脚本的退出码。
- 未启动应用、未写实时资料库、未 push、未合并。

## 取舍与风险

- 范围冲突：主题索引与主题页的页头（`WorkspaceHeading`）在
  `WorkspaceView.swift`（索引 L1022、主题 L1004），不在本波允许修改的两个
  文件内，因此「页头改用 WorkspacePageHeading」在那两处没有落地；阅读页内部
  能改的部分已全部收编。`TopicUnlinkedReferencesSection`
  （`TopicClaimConfirmViews.swift`）仍保留 `.bordered` 按钮，同样越界。
- 阅读卡去掉了旧 canvas 底色与行动色条，以换取全页同一种卡片容器；主题磁贴的
  hover 从底色切换改为 accent hairline，交互线索仍在但视觉更克制。
- 全景页新增 26pt 页头行，画布高度少约 48pt；这是「页头同名统一」的成本，
  换来与材料页、行动页一致的页面结构。
- 主次按钮按状态二选一，避免同屏两个主操作；空状态与工具栏可能同时出现
  一个禁用态主按钮（无法行动，不作为视觉主操作）。
- 未在运行中的应用里做视觉走查（本波不允许重启应用）；SwiftUI 视图不在测试
  覆盖内，验证强度是真实构建加 661 项核心测试，布局在窄宽度下的表现留给
  下一次人工审视。
