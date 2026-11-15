---
status: in_progress
started: 2026-11-16
updated: 2026-11-16
branch: work/mega-19
owner: coordinator
---

# 资料库打开慢的性能修复

## 目标

用户反馈最新版本打开资料库很慢。实测（隔离副本，279MB 库、79 来源、524 行动）：启动 18 秒后仍停在「正在打开资料库…」，30 到 60 秒才出现记录。目标是把打开资料库压到 3 秒内（与备份、镜像等后台任务解耦），并给出每阶段耗时证据。

## 已有证据

- `recover()` 总计 0.64 秒，其中 `recoverRecordingFollowups` 2.4 秒（出现在 recover 早段，计时以 remider_links 之后为准）。recover 不是 18 秒的成因。
- 启动期采样热点：`pread`、`validateUTF8`、`JSONWriter.serializeString`、`JSONScanner.DocumentReader.skipUTF8StringTillQuoteOrBackslashOrInvalidCharacter`，指向大 JSON（转写/声明/快照）的解码与编码。
- 启动路径：`ControlCenter.start()`（`VoiceOSApp.swift:808`）→ `store.recover()` → `refresh()` → `reloadWorkspace()`（`VoiceOSApp.swift:952`）→ `store.workspaceSnapshot()` 全量加载 sources/claims/actions/questions 并发布。之后还有 `writeMarkdownMirror`、`updateSpotlightIndex`、`backupLibrary`、`resumeRecordingFollowups` 等后台任务。
- 280MB 数据库，转写文本是大头。

## 单元

### S1 启动剖面与修复
- 给 `start()` 到首屏就绪的每个阶段加计时（临时探针，合并前删除或收敛为可开关的诊断），拿到每阶段毫秒数。
- 找出 18 秒的主要构成，按证据修复：全量转写是否在首屏必须；`workspaceSnapshot` 是否可以只取首屏所需字段；FTS 是否在启动时重建；镜像/Spotlight/备份是否阻塞首屏。
- 修复后复测同一副本，贴出前后每阶段耗时。

## 验证

- 首屏（记录列表出现）≤ 3 秒（同一副本、冷启动三次取中位）。
- 后台任务不阻塞首屏，且仍在后台完成。
- 全量 `swift test -j 2` 通过。

## 已知边界

- 不改数据语义与包格式；不牺牲启动后的功能。
- 测试提速波（`work/mega18-t1`）在并行，产品代码由本波独占；T1 只改测试。

## 结果

（待填）

## 链接

- `Sources/VoiceOSApp/VoiceOSApp.swift:808`
- `Sources/VoiceOSCore/Store.swift:40`
