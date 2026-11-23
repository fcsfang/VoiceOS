# 201 清掉「最近想法」数据管线（减法）

197 删除收件箱「最近想法」界面后，Core 里的聚合管线已无消费者：RecentContentIndex.recentThoughts(days:)、RecentThoughtEntry、RecentThoughtDay、快照字段 recentThoughts 与相关测试。

## 改动
- RecentContent.swift：删除聚合函数与两个类型、快照字段/参数/构造、build 尾部调用（约 −60 行）。
- RecentContentHomeSnapshotChecks：删除四条仅验证该管线的测试。
- 保留：RecentThoughtKind/RecentContentThought（digest 的线程与计数仍用）、days/digests/rows 等。

## 验证
parse_exit=0；集成构建 106 + 全量测试（584 − 4 = 580 预期）。
