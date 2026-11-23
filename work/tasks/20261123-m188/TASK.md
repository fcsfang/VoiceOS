# 188 笔记页（第三个视角）

用户问「要不要专门弄一个笔记页面」。判断：要，但不是复制材料页——材料页按来源、主题页按关切，缺的是按文章。笔记是表达级产物（跨多份材料），值得成为一级列表。

## 实现
- WorkspacePage 增加 notes（top-level），侧边栏「材料」之后新增「笔记」（doc.text 图标）。
- 新文件 NotesLibraryView：每个表达最新一篇笔记，按整理时间倒序；行显示标题 + 导语/首段预览 + 日期；搜索框在标题与正文里过滤；点开经 expressionKey 首成员打开材料页，落到同一正文与阅读位置。
- 复用 MaterialNoteHomeText（改为 internal）；数据用 recentMaterialNotes(limit: 500)，随 records/materialNotes 代际刷新。
- 空态两分：还没有笔记 / 搜索无匹配。

## 验证
parse_exit=0；集成构建 85；上机看分组列表与点开落点。
