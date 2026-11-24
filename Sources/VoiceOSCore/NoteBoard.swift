import Foundation

/// 笔记板上的一块组件。kind 是自由字符串：text/todo/claim/quote/insight/
/// callout/… 以及未来任何类型。引用块只存 id（actionID/claimID/sourceID），
/// 渲染时解析到实时记录——板上没有第二份事实；未知 kind 由界面降级渲染。
public struct NoteBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public var heading: String?
    public var paragraphs: [MaterialNote.Paragraph]?
    public let annotation: MaterialNote.Annotation?
    public let actionID: String?
    public let claimID: String?
    public let sourceID: String?
    public let spanID: String?
    public let quote: String?
    public var text: String?
    public let tone: String?
    public let titleOverride: String?

    public init(id: String, kind: String, heading: String? = nil, paragraphs: [MaterialNote.Paragraph]? = nil,
                annotation: MaterialNote.Annotation? = nil, actionID: String? = nil, claimID: String? = nil,
                sourceID: String? = nil, spanID: String? = nil, quote: String? = nil, text: String? = nil,
                tone: String? = nil, titleOverride: String? = nil) {
        self.id = id; self.kind = kind; self.heading = heading; self.paragraphs = paragraphs
        self.annotation = annotation; self.actionID = actionID; self.claimID = claimID
        self.sourceID = sourceID; self.spanID = spanID; self.quote = quote; self.text = text
        self.tone = tone; self.titleOverride = titleOverride
    }

    /// 引用失效（目标记录已不存在）时降级为文字块：保留模型写下的文字，
    /// 不把内容整块丢掉；没有可用文字时返回 nil。
    public func degradedToText() -> NoteBlock? {
        let body = [titleOverride, text, quote]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let body else { return nil }
        return NoteBlock(id: id, kind: "text", paragraphs: [MaterialNote.Paragraph(text: body)])
    }
}

public enum NoteBoardSanitizing {
    /// 引用块只能指向输入里真实存在的记录：todo 的 actionID、claim 的 claimID、
    /// quote 的 sourceID。失效引用降级为文字块；材料类块按产品决定不出现，
    /// 直接丢弃；未知 kind 原样保留，由界面降级渲染。
    public static func sanitized(_ blocks: [NoteBlock], actionIDs: Set<String>, claimIDs: Set<String>, sourceIDs: Set<String>) -> [NoteBlock] {
        blocks.compactMap { block in
            switch block.kind {
            case "todo":
                if let id = block.actionID, actionIDs.contains(id) { return block }
                return block.degradedToText()
            case "claim":
                if let id = block.claimID, claimIDs.contains(id) { return block }
                return block.degradedToText()
            case "quote":
                if let id = block.sourceID, sourceIDs.contains(id) { return block }
                return block.degradedToText()
            case "materials":
                return nil
            default:
                return block
            }
        }
    }
}

public enum NoteBoardAdapting {
    /// 旧笔记没有 blocks：每节转成一个文字块，文末长文转成 insight 块。
    /// 这样同一个界面可以同时承载新旧两种笔记。
    public static func blocks(for note: MaterialNote) -> [NoteBlock] {
        if let blocks = note.blocks, !blocks.isEmpty { return blocks }
        var blocks: [NoteBlock] = []
        for (index, section) in note.sections.enumerated() {
            guard section.heading != nil || !section.paragraphs.isEmpty else { continue }
            blocks.append(NoteBlock(id: "legacy-s\(index)", kind: "text",
                                    heading: section.heading, paragraphs: section.paragraphs))
        }
        for (index, annotation) in (note.closing ?? []).enumerated() {
            blocks.append(NoteBlock(id: "legacy-c\(index)", kind: "insight", annotation: annotation))
        }
        return blocks
    }
}

/// 板内引用解析：渲染与验证共用一份口径，避免「界面能解析、检查工具不能」的偏差。
public enum NoteBoardResolving {
    public struct Resolved {
        public let noteTitle: String
        public let noteCount: Int
        public let coreBlocks: Int
        public let todoBlocks: Int
        public let claimBlocks: Int
        public let unresolvedBlocks: Int
    }

    /// 对一批笔记汇总板结构：todo 与 claim 的引用能否在给定集合中解析。
    public static func summarize(_ notes: [MaterialNote], actionIDs: Set<String>, claimIDs: Set<String>) -> Resolved {
        var core = 0, todo = 0, claim = 0, unresolved = 0
        for note in notes {
            for block in NoteBoardAdapting.blocks(for: note) {
                switch block.kind {
                case "todo":
                    todo += 1
                    if let id = block.actionID, actionIDs.contains(id) { core += 1 } else { unresolved += 1 }
                case "claim":
                    claim += 1
                    if let id = block.claimID, claimIDs.contains(id) { core += 1 } else { unresolved += 1 }
                default:
                    core += 1
                }
            }
        }
        return Resolved(noteTitle: notes.first?.title ?? "", noteCount: notes.count, coreBlocks: core,
                        todoBlocks: todo, claimBlocks: claim, unresolvedBlocks: unresolved)
    }
}
