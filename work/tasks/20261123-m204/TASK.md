# 204 笔记板 P1+P2：块模型、板生成 v6 与渲染

依据 docs/product/笔记板设计（块级文档）.md 与用户四项决定：只读+勾选跳转、模型按相关性选、材料完全隐去、旧笔记保持原样。

## Core
- NoteBlock{id,kind,heading?,paragraphs?,annotation?,actionID?,claimID?,sourceID?,spanID?,quote?,text?,tone?,titleOverride?}；自由 kind。
- NoteBoardAdapting：旧笔记每节→text 块、closing→insight 块；同一界面承载新旧。
- NoteBoardSanitizing：todo/claim/quote 的引用必须来自输入快照，失效降级为文字块（保留文字）；materials 块丢弃（材料隐去）；未知 kind 保留。
- MaterialNote.blocks 可选；MaterialNoteAnchoring 同时清洗文字块段落（锚点/marks/批注）与 insight 批注引文。

## 生成 material-note-v6 / note-v5
- 输入新增 actions（id/title/state）与 claims（id/statement）快照；模型只能引用。
- 输出 blocks（文字块承载叙述与 marks/annotations；todo/claim/quote/insight/callout/自定义块由模型按相关性摆布）；材料标题与来源不上板。
- 校验失败的引用块降级；空板报错不保存。表达绑定与旧笔记兼容不变。

## 渲染
- BoardView：text（小节竖标+段落，含行内 marks 与就地批注、阅读位置探针改为 note.b.<block>.p<i>）、todo（勾选=completeActionLocally 写回、已完成收起划线）、claim（打开原话→材料页）、quote（安静引文条）、insight（批注块）、callout、未知降级卡片。
- 首页预览与搜索索引并入 blocks 文本。

## 测试 +2
旧笔记适配；引用失效降级与材料块丢弃；身份断言 v6/note-v5。

## 验证
parse_exit=0；构建 113（build+test+dist，重启延后）。
