---
status: done
started: 2026-10-29T02:21:16Z
updated: 2026-10-29T03:39:21Z
branch: main
pr: https://github.com/fcsfang/VoiceOS/pull/37
owner: 主会话
---

# 基线重组：运行时线成为产品基线

## 目标

把 main 的独有工作反迁到运行时线，运行时线成为产品基线，`main` 的树切换到这条线。旧的 main 作为历史保留。

## 范围

- 运行时线工作区恢复 main 独有的可达入口：英文练习、静默回顾、语义搜索、观点转行动、本地排期、分段预览、跟进摘要。
- 流程资产进入新基线：工作框架、验证技能、`work/`、文档职责表、PR 模板。
- 首页星图改动随运行时线一起成为基线。
- 文档：README、AGENTS、ADR042。

## 改动

- `Sources/VoiceOSApp`：恢复入口与视图接线。
- `.claude/skills`、`work/`、`docs/agents`、`.github`：从 main 迁入。
- `README.md`、`AGENTS.md`、`docs/adr/042-runtime-line-becomes-main.md`：基线文档。

## 非目标

- 不把主线的存储核心重写搬回运行时线。
- 不兼容旧 main 的 schema 43 资料库。
- 不在本次拆分运行时线的测试结构。

## 决策

- 运行时线成为产品基线，理由是资料库在运行时线，反迁成本约为正方向的百分之二，见 ADR042。

## 当前状态

已完成。PR #37 合入 main，旧 main 保存为标签，本地与远端只剩 `main`。

## 下一步

无。

## 验证

- 运行时基线 `swift test -j 4` 10 项通过。
- 合线后重新运行构建与测试。
- 真机验证：星图首页、恢复的入口、原有工作区页面。

## 链接

- [ADR042](../../docs/adr/042-runtime-line-becomes-main.md)
- 旧 main：`archive/main-migration-20261028`
- 运行时线归档：`archive/pre-migration-runtime-20261028`
