# 波 70 任务书（2026-11-18）：VoiceOS 无障碍标识与 agent 可操控性

## 背景（用户需求 2026-11-18）

开发期用 computer-use（AX 树 + AXPress）操控 VoiceOS 做 UI 验收。现状：主按钮有中文 label，可以按 label 寻址；但缺稳定机器标识，改文案即断；部分控件（分段控件、开关、日期选择、动态事项行、证据展开三角）无 identifier；AX 懒加载列表只实体化可视区附近元素（实现约束，本波不解决，验证时用滚动配合）。

用户目标：VoiceOS 有完善的无障碍支持，agent 乃至 VoiceOver 用户都能稳定操控主流程。

## 完成判据

1. 约定命名规范并写进任务书结果：`<区域>.<元素>[.<细节>]`，ASCII 小写与点号，例如 `nav.monitor`、`monitor.runCheck`、`monitor.filter.unhandled`、`monitor.item.<id>.complete`、`monitor.settings.push.webhook`。动态行把稳定 ID（如事项 id）放串中间，动作放末尾。
2. 覆盖主流程可交互元素（只加 identifier/label/hint，不改可见行为与文案）：
   - 侧栏六个导航入口与设置按钮；
   - 消息监测报告页：立即检查、未处理/全部切换、报告事项的 标记完成/不适用/原文与来源展开、历史行、来源启停与删除；
   - 消息监测设置页：时间选择、云端授权开关、推送通道分段、webhook 输入与保存、测试推送、QQ 起点、添加所选群、诊断按钮；
   - 处理页主按钮（重试/忽略/重新理解等既有交互）。
3. 无障碍审计顺手项：icon-only 按钮必须有 accessibilityLabel；分段控件与开关带中文 label；证据行等纯展示文本不强制。
4. 不改布局、不改文案、不加减功能；不加迁移；不碰 `ArticleExtractor.swift`（波 69 领地）与 Core/Platform 任何文件。
5. `swift build -j 2` / `swift test -j 2` 真实退出码 0（基线以合并波 69 后的 main 为准，先 merge main）；本波纯属性增补，不加单测。
6. 结果里给出 identifier 清单（file:line 与串值），供协调方安装后 AX dump 实机验证。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceView.swift`
- `Sources/VoiceOSApp/WorkspaceMonitorView.swift`
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift`
- 必要时 `Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSApp/SavedViews.swift` 等首页/顶部控件（最小增量）
- 不碰其他文件。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并、不重建 dist。
- 分支 `work/m70-a11y`，提交回报。

## 结果（2026-11-18）

分支 `work/m70-a11y`，代码提交 `657f025`。本结果所在提交为第二个 docs 提交。

### 命名规范

`<区域>.<元素>[.<细节>]`，全小写 ASCII 与点号。动态行把稳定 ID 放中间，动作放末尾。
区域为 `nav`、`monitor`、`processing`。示例：`nav.monitor`、`monitor.item.<id>.complete`、`monitor.settings.push.webhook`。

### identifier 清单

侧栏与顶部，`Sources/VoiceOSApp/WorkspaceView.swift`

- 648 `nav.home`、`nav.themes`、`nav.materials`、`nav.monitor`、`nav.actions`、`nav.initiate`。调用点 577-582 传入 ASCII 键，实际串值为 `"nav." + id`。
- 614 `nav.settings`。

消息监测，`Sources/VoiceOSApp/WorkspaceMonitorView.swift`

- 40 `monitor.page`
- 100 `monitor.runCheck`
- 150 `monitor.history.<report.id>`
- 178 `monitor.report.settings`
- 181 `monitor.report.recheck`
- 185 `monitor.report.push`
- 227 `monitor.filter`。分段控件容器，两个分段仍按中文标签「未处理」「全部」寻址。
- 305 `monitor.item.<item.id>.complete`
- 308 `monitor.item.<item.id>.dismiss`
- 312 `monitor.item.<item.id>.reopen`
- 323 `monitor.item.<item.id>`
- 366 `monitor.item.<item.id>.evidence`
- 408 `monitor.sources.settings`
- 422 `monitor.sources.addBuiltin`
- 445 `monitor.source.<source.id>.enabled`
- 448 `monitor.source.<source.id>.delete`
- 466 `monitor.source.<source.id>.start`
- 535 `monitor.settings.schedule.time`
- 551 `monitor.settings.cloudAuthorized`
- 569 `monitor.settings.push.channel`
- 577 `monitor.settings.push.webhook`
- 581 `monitor.settings.push.save`
- 590 `monitor.settings.push.test`
- 593 `monitor.settings.push.pushNow`
- 634 `monitor.settings.qq.save`
- 639 `monitor.settings.qq.diagnose`
- 650 `monitor.settings.qq.list`
- 677 `monitor.settings.qq.openPrivacy`
- 748 `monitor.settings.qq.conversation.<conversation.id>`
- 755 `monitor.settings.qq.start`
- 765 `monitor.settings.qq.addSelected`

处理，`Sources/VoiceOSApp/WorkspaceProcessingView.swift`

- 222 `processing.dictation.discard`
- 224 `processing.dictation.stop`
- 226 `processing.batch.stop`
- 227 `processing.recording.stop`
- 256 `processing.monitor.open`
- 261 `processing.monitor.pushRetry`
- 266 `processing.monitor.recheck`
- 275 `processing.library.retry`
- 298 `processing.panorama.retry`
- 307 `processing.intent.<intent.id>.configure`
- 309 `processing.intent.<intent.id>.stop`
- 315 `processing.intent.<intent.id>.retry`
- 320 `processing.intent.<intent.id>.ignore`
- 346 `processing.transcription.retryAll`
- 348 `processing.transcription.<source.id>.retry`
- 359 `processing.transcription.<source.id>.retry`。转写为空区，与 348 按材料状态互斥。
- 377 `processing.request.<request.id>.recheck`
- 379 `processing.request.<request.id>.stop`
- 397 `processing.segmented.<batch.id>.retry`
- 438 `processing.transcriptReview.retryAll`
- 440 `processing.transcriptReview.<source.id>.retry`
- 462 `processing.followup.retryAll`
- 464 `processing.followup.<sourceID>.retry`
- 476 `processing.knowledge.<review.id>.ignore`
- 481 `processing.knowledge.retryAll`
- 483 `processing.knowledge.<review.id>.retry`
- 493 `processing.topic.retry`
- 501 `processing.assistant.<execution.id>.open`
- 502 `processing.assistant.<execution.id>.ignore`
- 509 `processing.assistantAssessment.<issue.id>.retry`
- 523 `processing.reminder.<item.id>.reread`
- 552 `processing.reminderSync.check`
- 559 `processing.inbox.open`
- 567 `processing.reminderSync.retry`
- 569 `processing.settings.open`
- 654 `processing.transcription.<source.id>.trash`
- 676 `processing.external.<action.id>.confirm`
- 746 `processing.external.<group.sourceID>.confirmAll`

新增 identifier 修饰共 71 处。纯展示文本、既有 `workspace.savedView.<视图名>` 与 `recent.*` 未改。

### 判据落点

- 判据 1：命名规范见上。导航入口改用 ASCII 键，不再依赖中文标题。
- 判据 2：侧栏六个入口与设置按钮；监测页立即检查、未处理与全部切换、事项标记完成、不适用、重新打开、原文与来源展开、历史行、来源启停与删除；设置页时间选择、云端授权开关、推送通道、webhook 输入与保存、测试推送、QQ 起点、添加所选群、诊断；处理页重试、忽略、重新理解等主按钮均已覆盖。
- 判据 3：新增推送通道与无可见标签日期选择、推送地址、QQ 起点的中文 accessibilityLabel。范围内未发现缺 label 的 icon-only 按钮。
- 判据 4：仅增属性。未改布局与文案，未加迁移，未触碰 `ArticleExtractor.swift`、Core、Platform。
- 判据 5：构建前执行 `git merge main --no-edit`，当时 main 为 `f59c030`，波 69 尚未合并。`swift build -j 2` 退出码 0。`swift test -j 2` 退出码 0，607 项测试，0 失败，与基线一致。
- 判据 6：清单见上。

### 遗留风险

- SwiftUI 分段控件不能给单个分段设置 identifier。只能给容器 identifier，分段仍按中文标题寻址，改标题会断。
- AX 懒加载列表只实体化可视区附近元素，实机验证时需要滚动配合。
- 动态事项、来源、意图的 identifier 依赖数据层 ID。数据层 ID 变化时 identifier 随之变化。
