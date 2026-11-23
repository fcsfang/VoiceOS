# 195 成品优先落地：收件箱不再展开要点与原文

用户：成品与原材料的分层应成为整个软件的原则，而不只在笔记上。

## 改动（收件箱/旧首页）
- 右侧阅读器不再渲染【想法】线索分组、编号要点、看原话与「想慢慢做到」块；有笔记的条目只显示成品预览（标题+导语）与待处理信息（待办 badge/列表、行动反馈）；没有笔记时说一句「要点与原文在材料页」。
- 随【想法】面板一并移除线索重命名/合并/隐藏入口与相关组件：threadSection、ThoughtLine、ClueHeaderMenu、RecentClueRenameSheet、ClueRenameRequest、beginClueRename/mergeClue/setClueHidden/openOriginal（约 −240 行）。
- 保留：无想法/冻结观点的整理引导（organizePrompt）、openClaim（最近想法区仍用）、失败提示与状态。

## 原则（整体适用）
一级界面只放成品；原材料退到「查看材料与原文」等二级入口。后续可继续按此收紧材料列表行预览等表面。

## 验证
parse_exit=0；集成构建 100。
