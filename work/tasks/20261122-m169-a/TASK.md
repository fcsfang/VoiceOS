# 169-A 笔记域模型与版本存储（MaterialNote，迁移 v77）

## 背景（产品方向文档第一阶段）
VoiceOS 的核心产物从「材料详情 + 要点清单」转向一篇文章式思考笔记。本单元只做 Core 数据层：笔记的数据形状、存储、版本与失效判定、测试；生成与界面由后续单元消费本契约。

## 文件清单（只允许动这些）
- 新建 Sources/VoiceOSCore/MaterialNote.swift
- Sources/VoiceOSCore/Database.swift（仅追加 v76→v77 迁移块，遵循现有 `if user_version == "76" { transaction { … PRAGMA user_version=77 } }` 模式）
- 新建 Tests/VoiceOSCoreTests/MaterialNoteChecks.swift
- 如 PortablePackage 采用显式表清单：在清单中登记 material_notes（仅登记，不新增格式版本，除非现有机制要求；按代码实际机制决定并在回报说明）

## 数据形状（Codable, Sendable, Equatable；可增字段但不得破坏下列语义）
```swift
public struct MaterialNote: Codable, Sendable, Equatable {
    public struct Paragraph: Codable, Sendable, Equatable {
        public let text: String                      // 第一人称整理正文
        public let anchors: [Anchor]                 // 该段依据，可为空
    }
    public struct Anchor: Codable, Sendable, Equatable {
        public let quote: String                     // 生成时引用的原话
        public let sourceID: String
        public let transcriptVersionID: String?
        public let spanID: String?                   // 锚定后填充，失败为 nil
    }
    public struct Section: Codable, Sendable, Equatable {
        public let heading: String?                  // 短小标题
        public let paragraphs: [Paragraph]
    }
    public let title: String                         // 用户能认出的短标题（问句或短句）
    public let lead: String?                         // 导语
    public let sections: [Section]
}
public struct StoredMaterialNote: Sendable, Equatable {
    public let id: String
    public let expressionKey: String
    public let note: MaterialNote
    public let transcriptVersions: [String: String]  // sourceID -> transcriptVersionID
    public let modelIdentity: String?
    public let createdAt: String
}
```

## 存储与 API（extension VoiceOSStore）
- 表（v77）：`material_notes(id TEXT PRIMARY KEY, expression_key TEXT NOT NULL, transcript_versions_json TEXT NOT NULL, model_identity TEXT, created_at TEXT NOT NULL, note_json TEXT NOT NULL)`，索引 `material_notes_expression(expression_key, created_at)`。
- expressionKey 规范化：成员 sourceID 排序后以 `|` 连接。
- API：
  - `public func saveMaterialNote(memberSourceIDs: [String], note: MaterialNote, transcriptVersions: [String: String], modelIdentity: String?) throws -> StoredMaterialNote`（新增一行，保留历史版本）。
  - `public func latestMaterialNote(memberSourceIDs: [String]) throws -> StoredMaterialNote?`（按 created_at 最新；空成员返回 nil）。
  - `public func materialNoteIsCurrent(_ stored: StoredMaterialNote, currentTranscriptVersions: [String: String]) -> Bool`（所有成员版本一致即 current；成员缺失视为失效）。
- 不改既有表；不接入搜索索引。

## 测试（MaterialNoteChecks，新建）
1. 保存后可读回最新版本，字段逐项相等。
2. 成员顺序不同的两次调用命中同一 expressionKey。
3. 再保存生成新版本，latest 返回新版本且旧版本仍在库中（行数 2）。
4. 当前版本一致 → current；任一成员 transcriptVersionID 变化 → 失效。
5. 空成员 latest 返回 nil。

## 约束
- 不动生成/UI；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse` 真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：API 最终签名、迁移块、PortablePackage 决定与证据、parse 退出码、diff --stat。