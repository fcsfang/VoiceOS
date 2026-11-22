# 174-C 首页批量笔记读取三处确认项修复

来源：174-A 只读评审（wf_ace32409-475，两视角找茬 + 逐条对抗验证；5 候选去重后 3 类 CONFIRMED）。

## 确认项与修复
1. `latestMaterialNotes` 无逐键上限（MaterialNote.swift:104）：IN 查询物化每键全部历史 revision（含整段 note_json）再丢弃，成本随重生成历史无界增长。修复：相关子查询 `m.rowid = (SELECT rowid … ORDER BY created_at DESC, rowid DESC LIMIT 1)`，每键恰一行。
2. 无逐键容错（MaterialNote.swift:110）：单条最新笔记解码失败拖垮整批，包装层 try? 吞掉后首页全部笔记标题/预览消失。修复：单条 `try?` 跳过，仅该表达回退。
3. 首页首读超集查询（RecentContentHome.swift:952）：readingStates 未就绪时按全部材料发查询，落回后再发一次。修复：`readingStatesLoaded` 门控，未就绪键集合为空，就绪后一次读取。

## 验证
- 测试 +2（MaterialNoteChecks）：批量读每键只返回最新一版；单行损坏不拖垮其余笔记。
- 集成构建 63：真实退出码待记。
