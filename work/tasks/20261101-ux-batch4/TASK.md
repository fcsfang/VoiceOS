---
status: completed
started: 2026-11-01T20:10+08
updated: 2026-11-01T22:30+08
branch: main
pr: https://github.com/fcsfang/VoiceOS/pull/73, https://github.com/fcsfang/VoiceOS/pull/74, https://github.com/fcsfang/VoiceOS/pull/75
owner: 主会话
---

# 使用体验批次四：设计统一、死路修复与新入口

## 目标

让每一天打开 VoiceOS 的观感与操作一致：同一类页面共用一套尺寸、颜色和控件；弹窗里的“查看原文”真的能打开原文；首页、行动、材料、工具页不再各自漂移。顺带补上三个真实缺口：任务到期信息、菜单栏快速记录、完成后的结果记录入口。

## 范围

- 设计词汇：`WorkspaceDesign.swift` 已落地（PR #73），本批次让各页面采用。
- 六个互不重叠的工作流，各自在 worktree 中完成并自证 `swift build`：

| 工作流 | 文件 | 内容 |
| --- | --- | --- |
| 外壳 | WorkspaceView, WorkspaceProcessingView, MaterialManagementView | 导航快捷键、材料行、待办到期与去噪、空状态、搜索框、滚动保持、Escape |
| 全景 | PanoramaConstellation, ThoughtPanoramaView, PanoramaScreenModel | 背景配色、近期点图例、单元未核对提示、搜索框与图标无障碍 |
| 阅读 | WorkspaceSourceView, WorkspaceReadingViews, WorkspaceTopicReadingView, WorkspaceActivityViews | 停止使用确认、粘滞进度、反馈历史容错、宽度与编辑面统一、到期行 |
| 编辑面 | AssistantExecutionView, DiscussionView, WorkspaceDiscussionView, Reflection* , QuestionViews, ClaimReviewHistoryView, KnowledgeReviewView, TopicResurfacingCard, OutcomeFollowupView | 共享眉题、原文导航、结束讨论与取消代办确认、禁用原因、颜色与搜索框 |
| 工具页 | TextCaptureView, EnglishPracticeView, RecordingInbox, RecordingFollowupView, Reminder*, FullRecordingView, CorrectionImpactView, TranscriptSegmentationView, RecordingTitleEditor, ConfirmTaskView, NativePlayerView, TextCaptureDraft | 工具页头、编辑面、移除收件入口、禁用原因、颜色 |
| 应用层 | VoiceOSApp 单文件 | 菜单栏快速记录、⌘⇧R 只在成功时吞掉按键、创建行动的局部状态 |

## 非目标

- 不改数据库 schema、模型提示或全景生成管线。
- 不改任何涉及云端调用的默认行为与花费。
- 不引入新的第三方依赖。

## 吞吐检查点

- **阻塞的第一步。** 共享词汇（PR #73）与原文导航契约（PR #74）先合入 main，六个工作流才允许开工；否则各工作流会用不同的私有实现再漂移一次。
- **独立工作流。** 上表六组分文件互斥，可并行；每个工作流以 `swift build` 通过为完成判据，写完自检 diff 不留调试代码。
- **共享可变状态。** 只有 main 一棵主线；每个工作流独立 worktree 与分支，合入按外壳、全景、阅读、编辑面、工具页、应用层顺序串行 squash，冲突由主会话解决。
- **最小安全分解。** 工作流之间不交换文件；需要新共享组件时报告给主会话，由主会话在 `WorkspaceDesign.swift` 追加，避免六个人同时改一个文件。

## 结果

六个工作流全部返回并合入，共 31 个文件，627 增 326 删。

- 外壳：⌘1 到 ⌘4 顶级导航、⌘[ 返回、Escape 后退；待办行显示到期或逾期，默认“尚未登记完成”不再逐行重复；材料、搜索、行动空状态统一；行动页新增“完成后的结果”入口；导航不再清空各页滚动位置。
- 全景：主题画布背景；近期圆点图例与无障碍标签；“N 个单元尚未核对”替代裸 ID；搜索框与图标按钮统一。
- 阅读：停止使用确认；整理进度按当前材料派生；反馈历史读取失败保留旧数据并可重试；任务详情显示提醒到期；宽度、编辑面、错误色、圆角统一。
- 编辑面：四处共享 `WorkspaceHero`；弹窗原文跳转接通；回顾有进度；结束讨论、整理、取消代办、重新执行均先确认。
- 工具页：记录页头部统一；禁用按钮旁说明缺什么；收件箱新增移除入口与不再处理单份素材。
- 应用层：菜单栏快速入口；⌘⇧R 只在真正执行时吞键；创建行动局部反馈。

## 验证

- 每个工作流：`swift build` 通过。
- 集成后：`swift build` 通过，`swift test -j 4` 12 项 0 失败（44.4 秒）。
- `dist/VoiceOS.app` 按集成树重建并启动，逐页截图核对：首页、材料、行动、记录页。
- 实时资料库只读，未运行全景模型调用。

## 链接

- PR #73 设计词汇。
- PR #74 原文导航契约。
