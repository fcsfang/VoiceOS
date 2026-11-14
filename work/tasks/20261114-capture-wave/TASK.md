---
status: in_progress
started: 2026-11-14
updated: 2026-11-14
branch: work/capture-1
owner: coordinator
---

# 抓取层第一批（9.2）

## 目标

把 9.2 抓取与输入里可先做的一批落地。PDF 文本层、网页正文提取、全局热键录音、剪贴板捕获、文件夹监听。目标是让素材从文件、链接、剪贴板和文件夹四个入口进来，不需要先打开主窗口。

## 方法

沿用前几批。A1 文档导入先做，A2 系统抓取在 A1 落地后接续，两者都改 `VoiceOSApp.swift`，必须分轮。写入代理不编译，集成后只跑一次 `swift build -j 2` 与一次 `swift test -j 2`。

基线 `main` 为 `2b7fc2d`，schema 56，167 项测试。

## 数据形状

- `ArticleExtractor.extract(html:baseURL:)` 纯函数，返回标题与正文，剥离脚本、样式、导航噪声与标签，解码常见实体，正文不足 80 字返回 nil。
- `WebArticle.fetch(url:)` 只接受 http 与 https，20 秒超时，响应上限 4MB，UTF-8 解码失败时回退 latin1。
- `PDFText.extract(fileURL:)` 用 PDFKit 逐页取文字，返回全文与页数，全文为空抛错。
- `source_attachments` 的 MIME 白名单扩展 `pdf` 到 `application/pdf`，同一张表，不改 schema。

## 单元

### A1 文档导入（PDF 与网页正文）

文件：`Sources/VoiceOSApp/TextCaptureView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSCore/SourceAttachments.swift`、`Sources/VoiceOSPlatform/ArticleExtractor.swift`（新）、`Sources/VoiceOSPlatform/WebArticle.swift`（新）、`Sources/VoiceOSPlatform/PDFText.swift`（新）、`Tests/VoiceOSCoreTests/ArticleExtractorChecks.swift`（新）、`Tests/VoiceOSCoreTests/PDFTextChecks.swift`（新）、`Tests/VoiceOSCoreTests/SourceAttachmentChecks.swift`。

- PDF 导入：抓取页的「导入文字文件」与拖放都接受 .pdf，用 PDFText 提取全文填入草稿，标题取文件名。菜单栏拖放增加 pdf 分支，直接保存为外部文字材料、仅本地，并附 PDF 原件。附件 MIME 扩展后，材料页按附件类型显示「查看原图」或「查看原件」。
- 网页正文：抓取页新增「从链接导入正文」，输入 http 或 https 链接后抓取并提取正文，填入草稿，标题优先用页面标题，正文为空时提示。网络上失败进 `draft.error`，不覆盖现有草稿。
- 测试：ArticleExtractor 覆盖脚本与样式剥离、标题、实体解码、段落保留、过短返回 nil、无标题回退 host。PDFText 用 PDFKit 生成带文字的 PDF 再提取，断言文字与页数。SourceAttachmentChecks 把现有「pdf 被拒绝」改为「pdf 被接受」，改用 zip 作为拒绝样例。

### A2 系统抓取（全局热键、剪贴板、文件夹监听）

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSPlatform/GlobalHotKey.swift`（新）、`Sources/VoiceOSApp/FolderWatch.swift`（新）、`Tests/VoiceOSCoreTests/FolderWatchChecks.swift`（新）。

- 全局热键：用 Carbon `RegisterEventHotKey` 注册两个热键。Option Command D 切换口述，Option Command V 把当前剪贴板文字存为外部材料、仅本地。应用不在前台时也生效。菜单栏菜单项显示对应快捷键提示。
- 剪贴板捕获：只存当前剪贴板文本，不做历史挑拣。空剪贴板提示「剪贴板没有文字」。标题取首行，超长按既有规则。
- 文件夹监听：菜单栏新增「监听文件夹…」与「停止监听」。选择一个文件夹后，用 DispatchSource 监听目录写入，新出现的 pdf、图片、txt、md、音频与视频交给现有 `acceptDroppedFiles` 路由。按路径、大小与修改时间去重，记录存 UserDefaults，按资料库根路径分键。文件还没写完时等下一次事件再试。停止监听只停监听，不删记录。
- 测试：把去重与类型判定的纯逻辑放进 Core 可见的小类型，测试覆盖新文件、重复文件、未知类型、大小变化。Carbon 与 DispatchSource 不做自动化测试。

## 集成顺序

A1 先合入根分支，随后 A2。A1 与 A2 都改 `VoiceOSApp.swift`，A2 必须基于 A1 之后的根分支。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本核对：抓取页导入一份生成的 PDF，正文与标题进入草稿；从链接导入一个本地 http 服务返回的 HTML；菜单栏出现两个热键提示；剪贴板捕获生成材料；选择文件夹后放入一份 txt 自动进入材料。
- 全局热键在应用不在前台时的行为用系统事件核对，取不到时写明。

## 已知边界

- 网页正文提取是启发式，复杂页面可能带导航残留。
- PDF 只取文本层，扫描版不含 OCR；本轮不做页码跳回。
- 文件夹监听只监听一层目录，不递归。
- 分享扩展、App Intents、邮件入口、Quick Note、播客章节、语言识别与语音命令不在本批。

## 链接

- `docs/product/reference-products.md` 第 9.2 节
