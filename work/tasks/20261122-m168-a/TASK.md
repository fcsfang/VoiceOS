# 168-A 收件箱式首页（RecentContentHome）

## 背景（用户产品决定）
用户指出首页时间线与材料页高度重复，选择「收件箱式首页」方向：首页回答「现在要处理什么」，已读沉入材料页；保留右侧阅读器。复用现有 `SourceReadingState` 三态，不加新表。

## 改动
- `@AppStorage("voiceos.home.pendingOnly") showsOnlyPending = true`：默认「待处理」= 材料行只保留非已读（未读/在读），行动反馈行始终保留；「全部」恢复原时间线。
- 页头新增「待处理 / 全部」分段选择（时间线范围）。
- 行内：材料行元数据行前加状态点（未读=accent、在读=secondary、已读无点），note 文案分别显示 未读/在读/已读；「全部」下已读行标题降为 secondaryText。
- 行内 contextMenu：标为未读/在读/已读（复用 model.setReadingState，失败回滚本地状态）。
- 空态：待处理全部处理完时显示「待处理的都处理完了」+「查看全部」；真正无数据仍用原空态。

## 验证
`xcrun --sdk macosx swiftc -parse` 退出码 0；行为验证待集成构建与真机（截图通道恢复后）。