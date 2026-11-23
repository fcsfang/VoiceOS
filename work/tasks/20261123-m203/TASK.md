# 203 手账式行内样式：通用标记载体 + AttributedString 渲染

用户：希望重点词有颜色、整篇像手账；渲染方式要能承载未来多样格式。

## 选型
结构化行内标记 + AttributedString（不用 Markdown 字符串）：正文永远纯文本，marks 是并列数据 {text, style?, tone?}，均为自由字符串；渲染层把已知值映射为背景/下划线/粗细，未知值默认渲染；新增样式只改渲染层。块级已结构化，未来加列表/引用/便签只加块种类。

## 实现
- Core：MaterialNote.InlineMark{id,text,style?,tone?}；Paragraph.marks；旧笔记兼容。提示词 material-note-v5 / note-v4：marks 必须逐字子串，style/tone 自由。
- 锚定：marks 的 text 必须在段落正文里；改写过的标记直接忽略。
- 渲染：marker→低饱和暖色底（warm/accent/muted），underline→下划线（沿用文字色），bold/italic→强调；标题下短暖色下划线、小标题竖色标（固定视觉语言）。
- 测试：marks 解码 + 锚定丢弃不存在词句。

## 验证
构建 110 因 underlineColor 不在 SwiftUI AttributedString 作用域失败；已改为下划线沿用文字色，重建。
