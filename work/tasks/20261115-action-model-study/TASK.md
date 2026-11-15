---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: main
owner: coordinator
---

# 待办与问题与目标模型研究

## 目标

用户提出：现在的「待办 vs 问题与目标」产品逻辑是否该改，有没有更成熟的方案可学习。现状是同一张 `actions` 表的两种 kind（task / opportunity / ai_suggestion），澄清单向，提醒事项只认 task。本波只做研究：对照 GTD 与主流任务管理、知识管理产品的公开模型，产出带出处的对比与建议，供决定是否改数据模型。

## 单元

### A1 GTD 与项目型任务管理
OmniFocus（停滞项目、回顾、defer）、Things 3（项目、Someday、区域）、GTD 原书模型（澄清五问、下一步行动、将来也许、项目）。官网与官方手册为准，引用 URL。产出：项目与行动的关系如何建模、停滞项目如何被发现、Someday 如何与行动分开。

### A2 任务与工单型产品
Todoist、Linear、Notion、Apple Reminders。开放问题与不确定项如何被表示（标签、状态、收件箱）；提醒与完成的语义；问题型条目是否有一等公民。引用官方文档 URL。

### A3 知识与 AI 原生工具
Obsidian、Roam、Zettelkasten 与 SiYuan（用户在用）。开放问题作为笔记的表示法、如何被回看与收敛；「问题清单」类实践（open questions list、MOC）。引用官方文档与公开文章。

## 约束

- 只读研究，不改代码。
- 每个结论带出处；取不到的写明原因。
- 不把「我印象中的 GTD」当证据。

## 结果

（待填）

## 链接

- `docs/product/todo-and-questions.md`
- `docs/product/reference-products.md`
