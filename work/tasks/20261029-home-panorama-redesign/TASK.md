---
status: done
started: 2026-10-28T16:08:46Z
updated: 2026-10-29T03:39:21Z
branch: main
pr: https://github.com/fcsfang/VoiceOS/pull/37
owner: 主会话
---

# 首页思考全景重构

## 目标

首页从 42 个互不相干的方块，改成能看出主题之间关系和内容密度的全景视图，顶部说明压缩成一条工具栏。

## 范围

- 首页 `ThoughtPanoramaView` 的布局与信息密度。
- 原型阶段放在 `/tmp/voiceos-home-proto`，不进入仓库。

## 改动

- 新增 `Sources/VoiceOSApp/PanoramaConstellation.swift`：内容键、模型、确定性布局、相机、星图视图、边层、区域卡片、缩放控件。
- 重写 `Sources/VoiceOSApp/ThoughtPanoramaView.swift`：52 点工具栏、共享阅读栏、区域摘要、提纲弹层；删除网格、页脚、时间线排序和调色板。
- 只改视图层；`VoiceOSCore`、`PanoramaSelection` 和讨论 API 未动。

## 非目标

- 不改全景生成管线。当前快照是 23/25 单元的部分结果、relations 为 0，属于管线问题，另行处理。

## 决策

- 用 Prototype 流程出三个可切换方案，对比后定方向。
- 用户选定 A 星图。真实实现按 Feature 流程做两路并行设计草图后合成：底稿为第二份（单文件、单色身份、视图外布局计算），吸收第一份的锚定布局、绝对手势变换与紧凑 LOD（LOD 视成本）。
- 设计文档：`/tmp/arena-constellation/synthesis.md`。

## 当前状态

PR #36 打开，等待合并。真实资料库上验证通过：42 区域同屏、区域与问题检查器、缩放、图例。
基线分歧未决：实时资料库是运行时线的 schema 49，main 只支持到 43；本改动在两条线上都能编译运行，最终归属待用户决定。

## 下一步

合并 PR #36 后按工作流用只改 `work/` 的关闭 PR 记 done 和 PROGRESS。基线归属决定后，再决定是否把这两个文件同步到运行时线。

## 验证

- 本地 `swift build -j 4` 通过，`swift test -j 4` 7 项 0 失败。
- 真实资料库上用运行时线构建验证：星图、部分快照徽章、零联系图例、缩放按钮与 ⌘=、区域摘要、问题检查器（原话、更正、沿这条线索继续）逐项截图核对。

## 链接

- 数据来自 `~/Library/Application Support/VoiceOS/voiceos.sqlite` 的最新全景快照：42 区域、92 问题、229 条原话、0 条联系、23/25 单元。
