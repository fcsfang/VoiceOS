# 199 192–197 评审修复

来源：只读评审工作流（三视角 + 对抗验证，15 候选去重后 5 条：4 CONFIRMED + 1 PLAUSIBLE）。

1. 【中/疑似】线索覆盖遗留：195 删掉隐藏/合并入口后，旧 override 仍过滤收件箱待办且无处恢复。修复：publishHomeSnapshot 不再应用 recentClueOverrides（传空数组）；Core 过滤逻辑保留供回滚。
2. 【中】笔记页位置恢复空操作：noteReadingPage 把 restoreScroll 绑到 sourceScrollBinding("note-reading:<id>")，但 scrolled 绑的是 scrollPositions[scrollKey]。修复：scrolled 增加可选 scroll 参数，笔记页传入同一绑定。
3. 【低】冷启动误报「还没有整理成笔记」：提示改为仅在批量读取完成过一次后（notesLoaded）且无笔记时显示。
4. 【低】首日头部间距依赖异步最近笔记导致下跳：固定 20pt。
5. 【低】194 后逐段引文无渲染者：按文档阶段 1 的可追溯要求保留为审计数据，修正 MaterialNoteReadingView 过时注释（原文数据在「查看材料与原文」侧）。

## 验证
parse_exit=0；集成构建 103；笔记页冷启动「继续读」应落回上次段落。
