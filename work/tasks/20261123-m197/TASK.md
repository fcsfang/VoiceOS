# 197 收件箱撤掉「最近想法」聚合区

成品优先的第二处收紧：跨材料的「最近想法」观点列表与【想法】面板同属原材料层，整体撤掉。

## 改动
- 移除时间线顶部的「最近想法」折叠区与相关状态（recentThoughtsExpanded/Highlighted/RowID、recentThoughts、recentThoughtCount、toggleRecentThoughts、recentThoughtsEntry），约 −107 行。
- 键盘上/下与回车的命中序列只剩材料行；折叠区的空格激活逻辑随之删除。
- 首日头部间距条件从 recentThoughts 换为 recentNotes。
- Core 的 recents 快照仍会计算该聚合，暂不删除（无渲染入口，后续清理）。

## 验证
parse_exit=0；集成构建 102。
