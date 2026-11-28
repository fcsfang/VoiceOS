---
status: in_progress
started: 2026-11-28
updated: 2026-11-28
branch: codex/architecture-governance-20261128
pr: -
owner: codex
---
# VoiceOS 架构治理

## 目标

把现有产品行为收敛到明确的模块职责、单一事实来源和可验证的依赖方向。逐批迁移真实调用方，保留已有资料和对外契约。

## 范围

覆盖生产 Swift targets、Python 与 shell 工具链、持久化和备份、UI 状态、外部系统适配以及验证入口。按 [架构现状与任务池](ARCHITECTURE.md) 推进。

## 决策

基于既有父分支 `codex/edit-generated-content` 的日常版源码 `964c164`，在独立 worktree 开发。远端父分支为 draft PR #254，当前治理提交独立留在子分支。

## 当前状态

A01 已验证并提交。主应用、只读 CLI 和备份共用 SQLite 连接。SQLite schema 的当前版本由写端定义，历史迁移和导出包版本继续分别保存。打包前运行 CSQLite 导入边界检查。

## 下一步

推进 A02，把 Responses 端口、设置连接探针和双语译文迁移到同一请求构造；方案与契约见架构任务池。

## 验证

使用现有 Swift 测试和真实 CLI，所有写入使用隔离库。涉及 UI 行为的批次使用代表性资料验证真实应用。

A01：迁移前后各跑全量 Swift 测试，均为 592 项通过。实际导入/重投/导出/恢复保留原件哈希和来源 ID；原生应用打开隔离库录音时只读 CLI 可查询，自动备份通过完整性抽查。检查器已验证拒绝越界导入。
