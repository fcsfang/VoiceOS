# 190 有笔记时要点默认收起（172-A 落地）

用户反馈笔记应像文章；对应的 172-A 审计项：材料页旧版「核心要点」默认展开，与文章抢戏。

## 实现
- SourceFoldState.initial(transcript:notePresent:)：notePresent 时 thoughts 默认 false（内容摘要本就默认收起）。
- WorkspaceView.sourceFoldBinding：按 materialHasNote(id)（presence 会话缓存或首页笔记批量结果命中）决定初值，冷启动从材料列表进入也能判断。
- WorkspaceSourceView：笔记在页面打开后异步出现时（notePresent false→true），自动把已展开的要点收起一次；用户之后仍可手动展开。

## 验证
parse_exit=0；集成构建 95；上机看有笔记的材料页首屏是文章，要点收起。
