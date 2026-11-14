---
status: in_progress
started: 2026-11-14
updated: 2026-11-14
branch: work/quick-wins-3
owner: coordinator
---

# 快速赢面第三批

## 目标

完成第 9.1 节最后两项。图片 OCR 把截图与图片识别成外部文字材料并保留原图。选中即动作让材料全文可以选中一句，直接存为问题、复制或回听选中段。第三批完成后，9.1 的十九项全部有落点。权限渐进按现状满足，麦克风首次使用时请求，拒绝有应用内提示，应用没有本地通知子系统。

## 数据形状（schema 56）

`source_attachments` 一张表，图片原件与材料一对一。

```sql
CREATE TABLE source_attachments (
  source_id TEXT PRIMARY KEY REFERENCES sources(id),
  relative_path TEXT NOT NULL,
  mime TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
```

`SourceAttachment` 含 sourceID、relativePath、mime、bytes、createdAt。`attachSourceFile` 只收 png、jpg、jpeg、heic、tiff，按 TextCapture 的 staging 与 place 方式写入 `assets/<UUID>.<ext>`，0600，UPSERT 记录。重复写入只覆盖记录，旧文件保留为孤儿。`sourceAttachment` 回读。

`ImageOCR.recognize(fileURL:)` 在 VoiceOSPlatform，Vision 精确识别，语言中文与英文，结果按行拼接，无文字抛错。

## 单元

### Z1 图片 OCR（已集成）

文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/SourceAttachments.swift`、`Sources/VoiceOSPlatform/ImageOCR.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/TextCaptureView.swift`、`Tests/VoiceOSCoreTests/SourceAttachmentChecks.swift`。

行为：菜单栏拖放的图片走 OCR 后保存为外部文字材料并附原图，仅本地。抓取页拖入单张图片走 OCR 填入草稿，替换草稿沿用确认弹窗。抓取页保存只落识别文字，不附原图，这是已知边界。

### Z2 选中即动作（已集成）

文件：`Sources/VoiceOSApp/SelectableText.swift`、`Sources/VoiceOSApp/SelectionActions.swift`、`Sources/VoiceOSApp/WorkspaceSourceView.swift`。

行为：材料页新增「全文选读」，用 NSTextView 桥接只读可选中文本。选中后浮条给三个动作。存为问题保存为我的表达并打开新材料。复制写入剪贴板。回听把 UTF-16 选区换算成 scalar 偏移，找包含起点的 span 播放。加入讨论未做，需要改工作台外壳的入口。

### Z3 原图入口与 OCR 测试（接续）

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Tests/VoiceOSCoreTests/ImageOCRChecks.swift`（新）。

- 材料页在存在 `sourceAttachment` 时显示「查看原图」，点击用 `NSWorkspace` 打开原件；没有附件时不显示。
- 测试用 AppKit 渲染一张白底黑字的 PNG，调用 `ImageOCR.recognize` 断言识别出设定文字。若这台环境里 Vision 结果不稳定，测试改为只断言非空并记录原因。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：图片从菜单栏拖入后生成外部材料并保留原图；材料页出现「查看原图」；全文选读能选中并出现浮条。
- 原生选择回调与拖放属于系统交互，合成点击可能无法覆盖，取不到时在任务卡写明。

## 已知边界

- 加入讨论动作未做。
- 抓取页的图片预览不附原图，只有菜单栏拖放入口保留。
- 重复写入的旧图片文件不清理。
- 迁移包格式 48 不含 source_attachments。

## 链接

- `docs/product/reference-products.md` 第 9.1 节
- 第一批任务卡 `work/tasks/20261114-quick-wins-wave-1/TASK.md`
- 第二批任务卡 `work/tasks/20261114-quick-wins-wave-2/TASK.md`
