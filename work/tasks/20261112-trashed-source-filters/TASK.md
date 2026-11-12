---
status: started
started: 2026-11-12
updated: 2026-11-12
branch: work/trashed-source-filters
owner: coordinator
---

# 材料选择器排除回收站

## 目标

回收站里的材料不应再出现在「关联其他材料」与「答案出处」两个选择器里，避免把已冻结的材料重新接回当前理解。

## 决定

- 主题页「关联其他材料」过滤条件补 `!isTrashed`。
- 问题解决「答案出处」选择器同样补 `!isTrashed`。
- 同批检查过其他材料选择器。跟进来源选择器已有 `!localOnly`，而移入回收站必然置 localOnly，隐式排除；英文练习、思想回顾、讨论来源用 `saved/reference_only` 白名单；材料页搜索在标签过滤之后。都不需要改。

## 范围

- `Sources/VoiceOSApp/WorkspaceView.swift`：主题关联选择器。
- `Sources/VoiceOSApp/QuestionViews.swift`：答案出处选择器。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 95 项 0 失败。
- 实机核对未完成：侧栏在辅助功能里只有无名按钮，此前会话靠坐标点击驱动，而用户正在这台机器上工作、窗口被前台应用遮住，无法在不抢占屏幕的情况下导航到主题页。两个过滤条件复用的是「回收站」标签同款 `isTrashed` 判断。
- 手动核对路径：任一主题 → 展开「关联其他材料」，回收站材料不应出现；问题登记状态选「已解决」时的「答案出处」同理。

## 进展

- 2026-11-12 两处过滤完成，构建与测试通过，PR 待开。
