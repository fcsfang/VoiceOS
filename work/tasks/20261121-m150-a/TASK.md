# 150-A 材料页按代际缓存（WorkspaceView / VoiceOSApp）

## 背景
性能发现：`materialPage` 在每次 body 求值时构建 `MaterialReadingPage`（五个筛选各一遍全量遍历与排序），键盘处理器再构建一次，方向键每按一次约十次全量遍历；行内还反复派生标题与日期。本单元先做「页面级」缓存：数据代际不变时复用已建页面。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/VoiceOSApp.swift
- Sources/VoiceOSApp/WorkspaceView.swift

## 改动
1. **数据代际**：`ControlCenter` 增加 `@Published private(set) var recordsRevision = 0`；在 `applyCoreSnapshot` 中 `records = snapshot.sources` 之后自增（`&+= 1`）。不要在任何写路径之外自增。
2. **阅读状态代际**：WorkspaceView 的 `readingStates`（`[String: SourceReadingState]`）每次被写入（加载完成、markSourceOpened、setMaterialReading 等全部赋值点，先 grep `readingStates` 找全）随之自增本地 `@State private var readingStatesRevision = 0`。
3. **缓存盒**：在 WorkspaceView.swift 内新增文件私有
   ```swift
   private final class MaterialPageCache {
       struct Key: Equatable { let records: Int; let states: Int }
       var key: Key?
       var pages: [String: MaterialReadingPage] = [:]
   }
   ```
   WorkspaceView 持有 `@State private var materialPageCache = MaterialPageCache()`。
4. **materialPage 改走缓存**：
   ```swift
   private var materialPage: MaterialReadingPage {
       let key = MaterialPageCache.Key(records: model.recordsRevision, states: readingStatesRevision)
       if materialPageCache.key != key { materialPageCache.key = key; materialPageCache.pages.removeAll() }
       if let page = materialPageCache.pages[materialFilter] { return page }
       let page = MaterialReadingPage(records: model.records, filter: materialFilter, filters: SavedViewPage.materials.filters, readingStates: readingStates, catalog: recordCatalog, expressions: model.sourcePageIndex.expressionsBySourceID)
       materialPageCache.pages[materialFilter] = page
       return page
   }
   ```
   注意：`@State` 引用类在 body 中修改其成员是允许的（不会触发循环重渲染），但必须保证 key 变化时清空。
5. 键盘处理器（handleMaterialListKey / readingMaterials）不改逻辑，自动复用同一 `materialPage`。
6. 行为必须一致：筛选、计数、排序、行内容与选中不变。

## 约束
- 不改视觉、交互语义与业务；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、recordsRevision 的自增点、readingStatesRevision 覆盖的写入点清单、缓存命中路径、parse 退出码、diff --stat。