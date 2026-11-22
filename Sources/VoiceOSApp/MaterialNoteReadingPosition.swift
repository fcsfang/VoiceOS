import Foundation

/// 会话内的笔记阅读位置：键是笔记表达键（成员 sourceID 排序连接），值是
/// 阅读视图里的段落锚点 id。与应用同生命周期，跨启动不保留；产品文档阶段 2
/// 的验收是「继续读落到同一正文和阅读位置」，同一次运行内往返即可满足。
@MainActor
enum MaterialNoteReadingPosition {
    private static var anchors: [String: String] = [:]

    static func anchor(for expressionKey: String) -> String? { anchors[expressionKey] }

    static func record(_ anchor: String, for expressionKey: String) { anchors[expressionKey] = anchor }
}