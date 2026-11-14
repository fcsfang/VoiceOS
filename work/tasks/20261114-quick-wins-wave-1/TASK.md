---
status: merge-ready
started: 2026-11-14
updated: 2026-11-14
branch: work/quick-wins-1
pr: 147
owner: coordinator
---

# 快速赢面第一批

## 目标

按 `docs/product/reference-products.md` 第 9.1 节实现第一批快速赢面，共十项。系统入口五项，macOS 服务、菜单栏拖放、网页选区剪藏、x-callback-url、隐私清单。行动面三项，稍后预设、撤销条、专注旗标。阅读面一项，旁注。主题面一项，未链接引用。

## 方法

协调者管切分、集成与验证。五个写入代理并行，各自从 `work/quick-wins-1` 开分支在自己的 worktree 工作。代理只写代码，不编译，不启动应用，不更新 dist。这台机器 16GB 内存，并行编译会耗尽内存，这是用户明确约束。全部单元集成后只跑一次 `swift build -j 2`，修完编译错误后跑一次 `swift test -j 2`。

每个单元在任务卡里定义数据形状、文件边界和验收证据。代理不得越过文件边界，需要越界时在报告里说明并停下。

## 数据形状（schema 55）

在 `Sources/VoiceOSCore/Database.swift` 末尾追加一段 `if user_version == 54` 的迁移，事务内建四张表并把版本写为 55。同时把第 20 行的格式闸门从 `(0...54)` 改为 `(0...55)`。新表全部附加式，旧迁移包不带这些表也能恢复。

```sql
CREATE TABLE action_focus (
  action_id TEXT PRIMARY KEY REFERENCES actions(id),
  created_at TEXT NOT NULL
);
CREATE TABLE source_reading_states (
  source_id TEXT PRIMARY KEY REFERENCES sources(id),
  state TEXT NOT NULL CHECK(state IN ('unread','reading','read')),
  updated_at TEXT NOT NULL
);
CREATE TABLE claim_notes (
  claim_id TEXT PRIMARY KEY REFERENCES claims(id),
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE topic_claim_confirmations (
  topic_id TEXT NOT NULL,
  claim_id TEXT NOT NULL REFERENCES claims(id),
  command_id TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  PRIMARY KEY(topic_id, claim_id)
);
CREATE TABLE source_capture_metadata (
  source_id TEXT PRIMARY KEY REFERENCES sources(id),
  source_url TEXT,
  captured_at TEXT NOT NULL
);
```

存储 API，全部为 `extension VoiceOSStore`，同步方法，时间用 `ISO8601DateFormatter().string(from:)`，错误用 `VoiceOSError`。

`ActionFocus.swift`
- `public func focusedActionIDs() throws -> Set<String>`，只返回仍然存在、`validity='current'` 且 `state='open'` 的行动。
- `@discardableResult public func toggleActionFocus(actionID: String) throws -> Bool`，已存在则删除并返回 false，不存在则插入并返回 true。插入第四条前抛 `VoiceOSError("最多只能置顶 3 条专注行动")`。行动不存在或已关闭时抛错。

`SourceReadingState.swift`
- `public enum SourceReadingState: String, CaseIterable, Codable, Sendable { case unread, reading, read }`
- `public func sourceReadingStates() throws -> [String: SourceReadingState]`
- `public func setSourceReadingState(sourceID: String, state: SourceReadingState) throws`，UPSERT，来源必须存在。

`ClaimNotes.swift`
- `public struct ClaimNote: Identifiable, Sendable { public let claimID, body, createdAt, updatedAt: String; public var id: String { claimID } }`
- `public func claimNotes() throws -> [String: ClaimNote]`
- `@discardableResult public func saveClaimNote(claimID: String, body: String) throws -> ClaimNote`，正文去首尾空白后非空且不超过 1000 字，claim 必须存在。首次写入建 createdAt，重复写入保留 createdAt 只更新 updatedAt。
- `public func deleteClaimNote(claimID: String) throws`

`TopicClaimConfirmations.swift`
- `@discardableResult public func confirmTopicClaim(topicID: String, claimID: String, commandID: String = UUID().uuidString) throws -> Bool`，按 command_id 幂等，同一命令换内容抛错，已确认返回 false，新确认返回 true。
- `public func unconfirmTopicClaim(topicID: String, claimID: String) throws`
- `public func confirmedTopicClaimIDs(topicID: String) throws -> [String]`，按 created_at 排序。

`CaptureMetadata.swift`
- `public struct CaptureMetadata: Sendable { public let sourceID: String; public let url: String?; public let capturedAt: String }`
- `public func attachCaptureMetadata(sourceID: String, url: String?) throws`，UPSERT，来源必须存在，URL 只接受 http 或 https。
- `public func captureMetadata() throws -> [String: CaptureMetadata]`

## 单元

### W1 存储地基

文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/ActionFocus.swift`（新）、`SourceReadingState.swift`（新）、`ClaimNotes.swift`（新）、`TopicClaimConfirmations.swift`（新）、`CaptureMetadata.swift`（新）、`Tests/VoiceOSCoreTests/QuickWinsStorageChecks.swift`（新）。

要求：迁移与闸门按上面的 DDL。测试沿用现有测试的临时目录建库方式，覆盖专注上限三条与第四条报错、撤销专注、笔记保存与再次保存保留 createdAt、空正文与超长正文报错、确认幂等与取消确认、阅读状态 UPSERT、抓取元数据只收 http/https。测试可以在 `@testable` 下直接向数据库插入最小的 sources 与 claims 行，具体写法照 `CoreFlowTests.swift`。不改 `PortablePackage`，不改恢复与校验逻辑。

验收证据：任务卡 DDL 与代码逐条对应；测试文件列出上述断言。代理不运行测试。

### W2 系统入口

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/SystemCapture.swift`（新）、`Sources/VoiceOSCore/CaptureLink.swift`（新）、`Sources/VoiceOSCore/TextCapture.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`（只改 URL 路由一处）、`scripts/app/build.py`、`Resources/PrivacyInfo.xcprivacy`（新）、`Tests/VoiceOSCoreTests/CaptureLinkChecks.swift`（新）。

行为：
- `CaptureLink` 解析 `voiceos://capture`，查询项支持 `text`、`title`、`url`、`x-success`。text 与 url 至少一个非空，title 可空，x-success 必须是带 scheme 的合法 URL。纯函数，配测试。
- `WorkspaceView` 的 URL 入口只加一处分流：capture 链接交给 `model.acceptCaptureURL(url)`，其余仍走现有提醒链接逻辑。不要动这个文件的其它区域。
- `ControlCenter.acceptCaptureURL` 与 `ControlCenter.acceptCaptureRequest`：内容按外部资料、仅本地保存，正文取 text，仅 url 时正文就是该 URL，title 可空，保存成功后写 `attachCaptureMetadata`，x-success 存在时回调 `?source_id=`。拒绝时在状态栏显示原因。
- Services：`ApplicationDelegate` 设 `NSApp.servicesProvider = self`，实现 `captureText` 与 `captureFile` 两个 `@objc` 方法，签名照 AppKit 服务协议。文字走 acceptCaptureRequest，文件走 `acceptDroppedFiles`。
- 菜单栏拖放：在状态项按钮上覆盖一个拖放视图，接受文件 URL，拖入音频或视频走现有 `importFiles`，`.txt` 与 `.md` 读取后走文字保存，其它类型在状态栏说明不支持。覆盖视图不能吞掉单击，单击仍要弹出原菜单。实现方式自定，验收点是这条。
- `PrivacyInfo.xcprivacy`：声明 `NSPrivacyTracking=false`、空的 `NSPrivacyCollectedDataTypes`，`NSPrivacyAccessedAPITypes` 只为 `NSUserDefaults` 写 CA92.1。先全仓搜索其它 required-reason API，发现就如实加，并在报告里列出。`build.py` 把它复制进 `Contents/Resources`，并加 `NSServices` 声明两项，标题分别为「存入 VoiceOS（文字）」与「存入 VoiceOS（文件）」。

验收证据：解析测试覆盖正常、缺字段、坏 scheme、坏 x-success；`build.py` 差异包含 NSServices 与隐私清单复制；报告列出搜索到的 required-reason API。

### W3 行动面

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、`Sources/VoiceOSApp/ReminderSettingsView.swift`、`Sources/VoiceOSApp/ActionUndoControl.swift`（新，`extension ControlCenter`，可直接访问内部属性 `store`）、`Sources/VoiceOSCore/SnoozePresets.swift`（新）、`Tests/VoiceOSCoreTests/SnoozePresetChecks.swift`（新）。

行为：
- 稍后预设。`SnoozePreset` 提供今晚、明天、下周三个时间，纯函数，传入 `now` 与 `calendar`。今晚取今天 20:00，已过则取一小时后；明天取次日 09:00；下周取下一个周一 09:00，今天就是周一时加 7 天。`ReminderSettingsView` 在「安排日期」上方加三个预设按钮，点击后打开日期与具体时刻并写入预设时间。自定义就是继续用现有日期与时刻选择器，不新增第四个按钮。
- 撤销条。`WorkspaceTaskView` 在用户手动完成或不再跟进成功后显示 5 秒提示，文案分别为「已完成」与「已不再跟进」，带「撤销」。撤销调 `model.undoActionState(actionID:)`，新方法在 `ActionUndoControl.swift`：从 `store.actions(includeHistory: true)` 取当前记录，`setActionState(state: .open)`，然后 `refresh()`。撤销只恢复为 open，不恢复更早的历史状态。外部完成确认与 AI 状态变化不触发撤销条。
- 专注旗标。`focusedActionIDs` 与 `toggleActionFocus` 通过 `ActionUndoControl.swift` 的 ControlCenter 方法暴露给视图。`我的待办` 顶部新增「专注」小区块，按现有行动顺序列出被旗标的开放行动，最多三条。行动行右键菜单加「加入专注」或「移出专注」。专注分区独立于优先级和今天分组。

验收证据：`SnoozePreset` 测试覆盖三个预设、跨午夜、周一、非周一；专注存储测试在 W1。代理不运行测试。

### W4 旁注

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/ClaimNoteViews.swift`（新，含 `extension ControlCenter`）、`Tests/VoiceOSCoreTests/QuickWinsStorageChecks.swift` 以外不新增测试。

行为：材料页每条已整理观点下方显示旁注区。已有旁注以小字与「旁注」标记显示，和 AI 内容在排版上分开。写旁注用内联编辑器或 sheet，保存与删除走 W1 的 `saveClaimNote` 与 `deleteClaimNote`。加载在 `.task` 或现有数据刷新中完成，不阻塞首屏。材料页头部有抓取元数据时显示来源链接与抓取日期，只显示 http 或 https 链接并可直接打开。不改顶部导航和现有原话引用逻辑。

验收证据：代码列出保存、删除、空正文禁用、超长截断或禁用四处的处理；来源链接只在元数据存在时出现。

### W5 未链接引用

文件：`Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`、`Sources/VoiceOSCore/UnlinkedReferences.swift`（新）、`Sources/VoiceOSApp/TopicClaimConfirmViews.swift`（新，含 `extension ControlCenter`）、`Tests/VoiceOSCoreTests/UnlinkedReferenceChecks.swift`（新）。

行为：
- 纯函数 `UnlinkedReferences.candidates(topicTitle: String, sectionTitles: [String], linkedClaimIDs: Set<String>, topicSourceIDs: Set<String>, claims: [CandidateClaim]) -> [CandidateClaim]`。候选必须当前有效、未被拒绝、不属于 linkedClaimIDs、至少一个引用落在 topicSourceIDs，并且陈述包含主题词。主题词来自主题标题与各小节标题，按「、」「与」「和」「及」「/」切分，丢弃少于两个字符的片段，英文按词切分并忽略大小写。同一来源最多取三条，结果按命中主题词数量降序，再按陈述长度升序，总数上限五条。
- 主题阅读页在「沿时间看变化」之后加一节「提到这个主题但还没关联」，每个候选项显示陈述与来源标题，按钮「确认关联」写入 `confirmTopicClaim`。已确认的条目独立显示，带「取消关联」，走 `unconfirmTopicClaim`。空候选时整节不出现。
- 通过 `extension ControlCenter` 暴露读取 `model.claims`、`workspaceTopicSources` 与确认存储，不改 `VoiceOSApp.swift`。

验收证据：测试覆盖切词、英文大小写、同源上限、已关联排除、来源范围排除、排序与总数上限。代理不运行测试。

## 集成顺序

W1 先合入根分支，随后 W2、W3、W4、W5 依次 cherry-pick。W2 与 W3 都改 `WorkspaceView.swift`，W2 只碰 `onOpenURL` 与 `openReminder` 区域，W3 只碰行动页与行动行区域，冲突时手工按两边意图合并。

## 验证

- 集成后单次 `swift build -j 2`，修完错误再单次 `swift test -j 2`。
- 实机用隔离资料库副本，不用用户实时库。核对：`open 'voiceos://capture?text=...'` 落库并带抓取元数据；菜单栏拖一个音频文件进入导入队列；我的待办出现专注分区并能加入与移出；改天弹窗三个预设写入正确日期；完成任务后 5 秒内可撤销；材料页能写旁注并重开可见；主题页出现未链接引用并可确认与取消。
- 无法实机核对的项目在任务记录里写明原因。

## 已知边界

- 网页选区的标题与 URL 取决于系统服务传入的内容，浏览器只传选中文字时就只有正文与首行标题，抓取元数据里的 URL 为空。这一点在完成报告里说明。
- 迁移包格式 48 不含新表，导出的旧包恢复后没有专注、旁注、阅读状态与确认记录，比照 schema 54 的既有边界。
- 专注旗标不参与行动派生与提醒事项写入。
- 阅读状态的界面过滤属于第二批，本批只建存储。
- 菜单栏拖放的音频进入既有导入队列，PDF 与图片不在本批。

## 第二批（未开始）

批量选择、阅读状态过滤、悬停预览、图片 OCR、选中即动作、追问建议、逐句高亮、保存视图、权限渐进。

## 结果

2026-11-14 五个单元全部集成到 `work/quick-wins-1`。W1 `c0a5741`，W4 `f5b6403`，W3 `9c97074`，W5 `9a6829b`，W2 `263f8de`，集成修复 `bfdf112`。

`swift build -j 2` 通过。`swift test -j 2` 152 项 0 失败。新增测试覆盖存储六项、稍后预设九项、未链接引用八项、抓取链接解析五项。

集成时修了三处。未链接引用的 ControlCenter 扩展补 `async` 与 `await`，`VoiceOSStore` 是 actor。三处测试把 schema 断言从 54 改为 55。未链接引用一处测试数据按「陈述长度升序」规则调整。

## 实机核对

隔离资料库副本，不触碰实时库。

- 副本从 schema 54 打开后升到 55，应用正常启动，首页与材料页可读。
- 行动页顶部出现「专注 2」，两条旗标按现有顺序排在「我的待办」之前。
- 任务页完成一条行动后底部出现「已完成 · 撤销」。点撤销后行动回到 open，版本从 2 到 5，修订链四条完整。截图 `/tmp/qw1-undo2.png`。
- 材料页「核心要点」每条观点下有「添加旁注」，点开出现 1000 字编辑器与保存、取消、删除。截图 `/tmp/qw1-note-edit.png`。

## 未取到的实机证据

- 旁注正文的键盘输入没有进入 TextEditor。合成点击能打开编辑器，键盘事件落不进去，正文保存改由单元测试覆盖。
- 改天弹窗要求任务已同步到 Apple 提醒事项。副本没有提醒链接，弹窗按设计不打开。三个预设时间由 `SnoozePreset` 测试覆盖。
- 系统服务、菜单栏拖放与 `voiceos://capture` 没有端到端触发。URL 会路由到正在运行的实时实例，未经批准不能向实时库写入。解析与元数据落库由测试覆盖。
- 未链接引用需要真实主题快照，本轮没有生成主题，只验证了匹配规则与编译。

## 链接

- `docs/product/reference-products.md` 第 9.1 节
- 根分支 `work/quick-wins-1`
