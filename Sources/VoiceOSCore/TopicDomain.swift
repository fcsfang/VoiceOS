import Foundation

/// 人生维度：主题的上层分组，让不断累积的关切按稳定的角度收拢，而不是每次
/// 整理都散成新的主题。名单固定，模型只能从中选择；未归类的主题显示在最后。
public enum TopicDomain: String, CaseIterable, Codable, Sendable {
    case love = "爱情"
    case family = "家庭"
    case career = "职业"
    case money = "金钱"
    case health = "健康"
    case growth = "成长"
    case selfUnderstanding = "自我"
    case life = "生活"

    public static func normalized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Self(rawValue: raw)?.rawValue
    }
}

public struct TopicDomainCandidate: Codable, Sendable, Equatable {
    public let topicID: String
    public let title: String
    public let summary: String
    public init(topicID: String, title: String, summary: String) {
        self.topicID = topicID; self.title = title; self.summary = summary
    }
}

public struct TopicDomainInput: Codable, Sendable {
    public let topics: [TopicDomainCandidate]
    public init(topics: [TopicDomainCandidate]) { self.topics = topics }
}

public struct TopicDomainAssignment: Codable, Sendable, Equatable {
    public let topicID: String
    public let domain: String
    public init(topicID: String, domain: String) {
        self.topicID = topicID; self.domain = domain
    }
}
