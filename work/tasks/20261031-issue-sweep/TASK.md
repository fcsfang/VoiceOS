---
status: done
started: 2026-10-31T13:44:00Z
updated: 2026-11-01T01:12+08
branch: main
pr: https://github.com/fcsfang/VoiceOS/pull/47, https://github.com/fcsfang/VoiceOS/pull/48, https://github.com/fcsfang/VoiceOS/pull/49, https://github.com/fcsfang/VoiceOS/pull/52, https://github.com/fcsfang/VoiceOS/pull/54
owner: 主会话
---

# 夜间 issue 清扫

## 目标

把现有不依赖人工决策的 issue 全部给出结局，并修复其中真实存在的问题。

## 改动

- #20 claim schema 与校验对齐，带 claim 索引的诊断。
- #40 执行路径接受冻结历史的已裁剪占位；#41 显式现有任务必须同目标。
- #39 主题与材料页滚动位置恢复。
- #44 冻结任务的外部完成状态呈现（展示切片，剩余确认入口与用例保持开放）。
- #50 解码错误带字段路径。

## 决策

- #21 到 #25、#15、#13 以基线合入的代码与提交证据关闭；#42、#43 复核为历史状态后关闭。
- #44 只做展示，确认入口涉及产品行为，留待对齐。

## 验证

每个 PR 都有构建与 10 项测试；全景与滚动之外的行为在真实资料库上做了数据库级核对。合并后 main 构建与测试通过。

## 下一步

#44 剩余部分、#45、#51、#55 见 issue 列表。
