# 175-B 首页笔记标题首帧缓存与「继续读」入口

来源：174-A 评审确认项（返回首页首帧先按旧标题渲染，异步读完整列跳变）；产品文档阶段 2 要求首页提供「继续读」入口。

## 实现
- ControlCenter（VoiceOSApp.swift）新增 `@Published private(set) var materialNoteRows: [String: StoredMaterialNote]` 会话缓存；切换资料库清空（与 materialNoteStates/materialNotePresence 同路径）。
- `latestMaterialNotes(expressionKeys:)` 包装层：读取成功且内容变化时整体替换缓存；失败保留旧缓存（不再返回空字典清空界面）。
- RecentContentHome 删除视图内 @State materialNotes，改为直接读 `model.materialNoteRows`（@ObservedObject 发布驱动重绘），返回首页首帧即用缓存渲染笔记标题与预览。
- 阅读器元数据行按钮：有笔记时「继续读」（help「继续读这篇笔记」），无笔记维持「打开材料」。

## 验证
- parse 真实退出码；集成构建 65；上机：材料页返回首页首帧标题不跳变、按钮文案正确。
