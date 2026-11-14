---
status: in_progress
started: 2026-11-14
updated: 2026-11-14
branch: work/capture-2
owner: coordinator
---

# 抓取层第二批（9.2）

## 目标

补上前台上下文与 Quick Note 式速记。任意前台应用按 ⌥⌘N 打开一块小速记面板，自动带上当前应用与窗口标题，保存后回到原应用。剪贴板捕获也带上同样的上下文。材料页显示上下文。

## 方法

单单元，写入代理不编译，集成后只跑一次 `swift build -j 2` 与一次 `swift test -j 2`。

基线 `main` 为 `85f5fe0`，schema 56，181 项测试。

## 数据形状（schema 57）

`source_capture_metadata` 增加 `context TEXT` 列。

```sql
ALTER TABLE source_capture_metadata ADD COLUMN context TEXT;
```

- `CaptureMetadata` 增加 `context: String?`。
- `attachCaptureMetadata(sourceID:url:context:)` 增加可空 context，默认 nil，UPSERT 同时写两列。
- `recordCapturedText` 增加可空 `captureContext`，与 `sourceURL` 一起在保存后写入元数据。
- `acceptCaptureRequest` 增加可空 `context`，透传到保存。
- 前台上下文由 `FrontContextReader.current()` 读取当前前台应用名与最前窗口标题。用 `NSWorkspace.frontmostApplication` 与 `CGWindowListCopyWindowInfo`，不需要辅助功能权限。窗口标题去空白，超过 120 字截断。没有窗口标题时只显示应用名。

## 单元

### B1 前台上下文与速记

文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/CaptureMetadata.swift`、`Sources/VoiceOSCore/TextCapture.swift`、`Sources/VoiceOSPlatform/FrontContext.swift`（新）、`Sources/VoiceOSApp/QuickNote.swift`（新）、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Tests/VoiceOSCoreTests/CaptureContextChecks.swift`（新）、schema 断言所在的既有测试。

行为：
- 全局热键 ⌥⌘N 打开速记面板。面板是一个浮动 NSPanel 加 NSHostingView，不依赖主窗口。面板有关联的应用与窗口标题、可留空的标题、正文、保存与取消。正文为空时不能保存。
- 保存走现有外部资料、仅本地路径，并写入上下文。保存后关闭面板并把焦点还给打开前的应用。取消同样还焦点。
- 剪贴板捕获（⌥⌘V）与速记都调用 `FrontContextReader.current()`，把结果写进抓取元数据。
- 菜单栏新增「速记（⌥⌘N）」。材料页的抓取元信息行显示上下文，例如「来自 Safari · 某页面」。
- 测试：元数据 context 写入与回读、url 与 context 同时存在、来源不存在报错；FrontContext 的 display 拼接与截断；五处 schema 断言从 56 改为 57。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本：在终端前台按 ⌥⌘N，面板出现并显示 Terminal 上下文；输入文字保存后，材料页出现该材料并显示上下文。
- 面板焦点与还原、菜单项截图取不到时写明。

## 已知边界

- 选中文字需要辅助功能权限，本轮只取应用名与窗口标题。
- 语言自动识别按现状满足，应用从不要求用户先选语言。
- 语音命令需要流式识别，当前在停止后转写，本轮不做。
- 播客章节、分享扩展、App Intents、邮件入口不在本批。分享扩展需要 .appex 与容器共享，App Intents 需要 SwiftPM 之外的 Intent 元数据处理，邮件需要收信服务或 IMAP 凭据。

## 链接

- `docs/product/reference-products.md` 第 9.2 节
- 抓取层第一批任务卡 `work/tasks/20261114-capture-wave/TASK.md`
