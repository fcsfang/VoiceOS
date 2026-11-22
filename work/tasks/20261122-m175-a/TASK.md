# 175-A 材料页重开恢复笔记阅读位置

来源：产品文档阶段 2「记录与重访」——「继续读」落到同一正文和阅读位置。上机实测确认：打开材料页滚动后返回首页再打开，落回页面顶部。

## 实现
- 新文件 MaterialNoteReadingPosition.swift：会话级位置存储，键 = VoiceOSStore.materialNoteExpressionKey(成员 sourceIDs)，值 = 段落锚点 id。
- MaterialNoteReadingView：
  - 笔记标题 `.id("note.title")`、每段 `.id("note.p.<节>.<段>")`，各挂 `.onGeometryChange` 探针读取 `frame(in: .scrollView(axis: .vertical)).minY`；探针值存非观察引用盒，避免滚动每帧重算视图。
  - 视口顶部线（96pt）之上最近的块记为当前阅读位置，变化才写入会话存储；恢复完成前不记录（防止把页面顶部写回）。
  - 显示完成后一次性恢复：等 120ms 布局，再 `scroll.wrappedValue.scrollTo(id:anchor:.top)`；无记录/无 scroll/锚点不存在时不滚动。
- WorkspaceSourceView 调用点传入 `restoreScroll: scroll`。

## 验证
- parse_exit=0；集成构建 64 结果与上机复测见 STATUS。
