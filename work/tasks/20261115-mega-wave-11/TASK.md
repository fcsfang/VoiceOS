---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-11
owner: coordinator
---

# 并行大波第十一批（增量阅读）

## 目标

把长材料切成按天推进的块。只存每份材料的块游标，块边界按当前转写确定性重算；转写版本变化时游标收敛到有效范围。材料页给「按天读」模式与今日阅读队列。基线 `main` 为 `aaaeed4`，312 项测试。

## 数据形状（schema 61，P1 独占）

```sql
CREATE TABLE incremental_reading (
  source_id TEXT PRIMARY KEY REFERENCES sources(id),
  chunk_size INTEGER NOT NULL,
  current_chunk INTEGER NOT NULL DEFAULT 0,
  transcript_version_id TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

- `IncrementalPlan` 含 sourceID、chunkSize、currentChunk、transcriptVersionID、updatedAt。
- 存储 API：`incrementalPlan(sourceID:)`、`startIncrementalReading(sourceID:chunkSize:)`（默认 1200，限 400 到 4000）、`setIncrementalChunk(sourceID:index:)`（夹到 0...total-1）、`advanceIncrementalChunk(sourceID:)`（末块返回 false）、`stopIncrementalReading(sourceID:)`、`incrementalPlans()`。
- `ReadingChunks.split(text:spans:targetSize:)` 纯函数：按 span 边界与换行切段合并到 targetSize，超长硬切；返回块数与每块字符范围；确定性，同输入同输出。

## 单元

### P1 存储与切块
文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/IncrementalReading.swift`（新）、`Tests/VoiceOSCoreTests/IncrementalReadingChecks.swift`（新）；schema 断言 60 改 61。
- 迁移 60→61，守卫 0...61。
- 游标读取时若当前转写版本与存储不同，把 current_chunk 夹到 [0, total-1] 并回写新版本。
- 测试：切块大小与硬切、起点终点覆盖全文、游标夹取、推进到末块、版本变化收敛、start 校验范围。

### P2 阅读页按天读与今日队列
文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/IncrementalReadingView.swift`（新）、`Sources/VoiceOSApp/WorkspaceView.swift`。
- 材料页工具区加「按天读」入口：未开始时提供「开始按天读」；已开始时显示当前块（第 N/M 块）与该块原文，按钮「上一块」「下一块」「读完了，明天继续」（推进并提示）、「结束按天读」。
- 材料页（列表页）顶部在存在活跃计划且今天未推进时显示「今日阅读」区块，最多 3 条，点击进入该材料。
- 不改阅读页其他区块；不自动改变阅读状态。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机不可得时写明（锁屏）。

## 已知边界

- 只存游标不存切块缓存，转写变化后块边界可能变化，游标夹取。
- 今日队列按 updated_at 日期判定，不做每日配额合计。
- 不做按天提醒通知。

## 链接

- `docs/product/reference-products.md` 第 9.3 节
