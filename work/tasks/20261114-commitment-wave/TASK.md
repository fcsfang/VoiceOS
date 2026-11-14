---
status: merge-ready
started: 2026-11-14
updated: 2026-11-14
branch: work/commitment-1
owner: coordinator
---

# 承诺层第一批（9.4）

## 目标

把每周回顾从只读升级为可以收尾。新增每日收尾区块，列出今天与逾期的开放行动，逐条完成或放下，显示剩余条数与全部处理完的状态。不做排期写入，改天仍走任务页。

## 文件

`Sources/VoiceOSApp/WeeklyReviewView.swift`、`Sources/VoiceOSCore/DailyReview.swift`（新）、`Tests/VoiceOSCoreTests/DailyReviewChecks.swift`（新）。

## 行为

- DailyReview 纯函数，输入行动、排期意图、提醒链接与当前时间，输出今天、逾期与其余开放三组，以及已完成、已放下计数。复用 ActionTimeSurface 的分组口径，不重复实现日期判断。
- WeeklyReviewView 顶部加「今天收尾」区块。每行显示标题与来源，按钮「完成」「不再跟进」。执行走现有 model.changeAction，完成后从列表移除并更新计数。
- 全部处理完显示「今天没有未收尾的行动」。逾期条目单列并标「逾期」。
- 不改每周回顾其余区块，不写 Apple 提醒事项，不做批量。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- DailyReview 测试覆盖今天、逾期、分组排序、空列表。
- 实机用隔离副本打开行动页的每周回顾，核对区块与两条出口。

## 结果

2026-11-14 C1 集成在 `work/capture-2`，提交 `7e7caa6`。`swift test -j 2` 191 项 0 失败，其中 DailyReview 6 项。新增今天与逾期的分组、计数、两条出口与空状态。隔离库没有任务，实机未核对每周回顾界面。

## 链接

- 2026-11-14 与抓取层第二批同一 PR 合并。
- `docs/product/reference-products.md` 第 9.4 节
