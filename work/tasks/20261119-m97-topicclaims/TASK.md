# 波 97 任务 A：主题卡先给观点，维护横幅限定当前主题

## 背景

用户要打开页面就看到它带来什么。只读发现者用真实库证实：主题详情的 3 张概览阅读卡只显示标题、摘要与折叠的「相关观点（n）」，观点默认藏起；另有全库级「主题整理未完成 · N 个主题待补齐」横幅在任意主题页顶部出现，与本主题无关。

只读复核（`voiceos.sqlite`，93 个主题）：376 个小节，374 个有当前观点；2 个主题有小节但无当前观点（「私人网页入口与多端知识同步」「通用网关的自动压缩策略」）；当前库中 bodyPending 为 true 的主题为 0。

## 改动

- `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift:275` 阅读卡取 `previewClaims = sectionClaims.prefix(2)`，数据仍来自 `TopicReadingData.sectionClaims`。
- `:284` 摘要之后内联每一条预览观点的归属与正文，正文 `lineLimit(2)` 截断。
- `:295` 原「相关观点（n）」折叠组原样保留，包含全部观点的完整正文、更正/停止使用按钮与计数，标识与键盘行为未动。
- `:32` 新增 `sectionsWithoutClaims`：小节非空且所有小节都没有观点。
- `:155` 概览速览卡内显示一行「这些小节的原文已保留，尚未关联观点」，无操作按钮。
- `:112` 维护横幅改为只在当前主题 `bodyPending == true` 时出现。
- `:165` 横幅文案改为「主题整理未完成 · 正文待补齐」，不再引用全库 `topicOrganizationPendingTopicCount`；「补齐正文」按钮与整理中进度不变。
- 过期横幅（`TopicStaleBanner`）未改。

提交：`d8b577e` 内联观点预览；第二次提交含横幅限定、速览提示与本记录。

## 验证（真实退出码）

- 基线（改动前）：`swift build -j 2; echo build_exit=$?` → `build_exit=0`（127.04s）；`swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 645 tests, with 0 failures`（55.782s）。
- 第一组（内联预览）：`build_exit=0`（5.31s）；`test_exit=0`，`Executed 645 tests, with 0 failures`（47.016s）。
- 第二组（横幅与速览提示）：`build_exit=0`（30.88s）；`test_exit=0`，`Executed 645 tests, with 0 failures`（43.278s）。
- 未加测试，基线 645 项不变。

## 取舍与遗留风险

- 内联预览重复展示折叠组里已有的前 1-2 条观点。若从折叠组移除，会连带丢失这些观点的「更正理解或归属」「停止使用」入口与计数；保留折叠组是更小的改动，折叠状态下看不到重复。
- 横幅文案去掉全库计数，让提示只谈当前主题；全库待补齐数量仍在处理页与首页提醒里可见，入口没有消失。
- 未重启应用、未做真实 GUI 查看。风险是窄列（自适应最小 290pt）下两张卡各带两条内联观点时的视觉密度，需要人工过目。
- 速览提示在 bodyPending 主题上也可能出现（与「正文整理中」同屏）；当前库没有 bodyPending 主题，未观察到该组合。
- 未改数据流、未做迁移、未写实时库、未 push、未合并 main。