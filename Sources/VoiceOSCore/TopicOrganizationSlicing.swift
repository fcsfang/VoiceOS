import Foundation

/// The two model-facing stages of topic organization. The skeleton sees
/// viewpoints only; each body batch sees the statements and short verbatim
/// quotes of the topics assigned to it. Full transcripts stay local.
public struct TopicSkeletonTopicSeed: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct TopicSkeletonViewpoint: Codable, Sendable, Equatable {
    public let id: String
    public let statement: String
    public let sourceID: String
    public let occurredAt: String
    public init(id: String, statement: String, sourceID: String, occurredAt: String) {
        self.id = id; self.statement = statement; self.sourceID = sourceID; self.occurredAt = occurredAt
    }
}

public struct TopicSkeletonInput: Codable, Sendable {
    public let digest: String
    public let topics: [TopicSkeletonTopicSeed]
    public let viewpoints: [TopicSkeletonViewpoint]
    public init(digest: String, topics: [TopicSkeletonTopicSeed], viewpoints: [TopicSkeletonViewpoint]) {
        self.digest = digest; self.topics = topics; self.viewpoints = viewpoints
    }
}

public struct TopicSkeletonTopic: Codable, Sendable {
    public let topicID: String
    public let title: String
    public let summary: String
    public var questions: [String]? = nil
    public let viewpointIDs: [String]
    public init(topicID: String, title: String, summary: String, questions: [String]? = nil, viewpointIDs: [String]) {
        self.topicID = topicID; self.title = title; self.summary = summary
        self.questions = questions; self.viewpointIDs = viewpointIDs
    }
}

public struct TopicSkeletonResult: Codable, Sendable {
    public let briefing: String
    public let highlightSourceIDs: [String]
    public let topics: [TopicSkeletonTopic]
    public let responseID: String
    public init(briefing: String, highlightSourceIDs: [String], topics: [TopicSkeletonTopic], responseID: String) {
        self.briefing = briefing; self.highlightSourceIDs = highlightSourceIDs
        self.topics = topics; self.responseID = responseID
    }
}

public struct TopicBodyQuote: Codable, Sendable, Equatable {
    public let sourceID: String
    public let quote: String
    public init(sourceID: String, quote: String) { self.sourceID = sourceID; self.quote = quote }
}

public struct TopicBodyTopic: Codable, Sendable {
    public let topicID: String
    public let title: String
    public let summary: String
    public let sourceIDs: [String]
    public let viewpoints: [TopicSkeletonViewpoint]
    public let quotes: [TopicBodyQuote]
    public let tasks: [TopicTask]
    public init(topicID: String, title: String, summary: String, sourceIDs: [String],
                viewpoints: [TopicSkeletonViewpoint], quotes: [TopicBodyQuote], tasks: [TopicTask]) {
        self.topicID = topicID; self.title = title; self.summary = summary; self.sourceIDs = sourceIDs
        self.viewpoints = viewpoints; self.quotes = quotes; self.tasks = tasks
    }
}

public struct TopicBodyInput: Codable, Sendable {
    public let digest: String
    public let topics: [TopicBodyTopic]
    public init(digest: String, topics: [TopicBodyTopic]) { self.digest = digest; self.topics = topics }
}

public struct TopicBodyTopicResult: Codable, Sendable {
    public let topicID: String
    public var questions: [String]? = nil
    public let sections: [TopicReadingSection]
    public init(topicID: String, questions: [String]? = nil, sections: [TopicReadingSection]) {
        self.topicID = topicID; self.questions = questions; self.sections = sections
    }
}

public struct TopicBodyResult: Codable, Sendable {
    public let topics: [TopicBodyTopicResult]
    public let responseID: String
    public init(topics: [TopicBodyTopicResult], responseID: String) {
        self.topics = topics; self.responseID = responseID
    }
}

/// Some batches may finish while others fail. The completed topics stay
/// readable; the caller reports how many still need a top-up.
public struct TopicOrganizationIncomplete: Error, Sendable, LocalizedError, Equatable {
    public let topicCount: Int
    public let firstReason: String
    public init(topicCount: Int, firstReason: String) { self.topicCount = topicCount; self.firstReason = firstReason }
    public var errorDescription: String? {
        let suffix = firstReason.isEmpty ? "" : "。最近原因：" + firstReason
        return "\(topicCount) 个主题待补齐；已完成的主题会保留，可稍后补齐" + suffix
    }
}

struct TopicBodyPlan: Sendable {
    let input: TopicBodyInput
    let scope: String
    var digest: String { input.digest }
}

struct TopicSkeletonDigestInput: Encodable {
    let version: String
    let viewpoints: [TopicSkeletonViewpoint]
    let manualTopics: [TopicSkeletonTopicSeed]
}

struct TopicBodyDigestInput: Encodable {
    let version: String
    let input: TopicBodyInput
}

enum TopicOrganizationSlicePolicy {
    static let skeletonByteLimit = 120 * 1024
    static let bodyByteLimit = 40 * 1024
    static let bodyPackingTarget = 36 * 1024
    static let bodyBatchTopicLimit = 5
    static let statementScalarLimit = 160
    static let quoteScalarLimit = 200

    static func shortened(_ text: String, scalars limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        return String(scalars[..<scalars.index(scalars.startIndex, offsetBy: limit)])
    }

    static func scalarSlice(_ text: String, start: Int, end: Int) -> String {
        let scalars = text.unicodeScalars
        let lower = max(0, min(start, scalars.count)), upper = max(lower, min(end, scalars.count))
        return String(scalars[scalars.index(scalars.startIndex, offsetBy: lower)..<scalars.index(scalars.startIndex, offsetBy: upper)])
    }
}

enum TopicOrganizationSlicingValidation {
    static func skeleton(_ result: TopicSkeletonResult, input: TopicSkeletonInput, allowedSources: Set<String>) throws {
        let viewpointIDs = Set(input.viewpoints.map(\.id)), seedIDs = Set(input.topics.map(\.id))
        var assigned = Set<String>(), usedTopicIDs = Set<String>()
        guard !result.responseID.isEmpty, !result.topics.isEmpty,
              !result.briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(result.highlightSourceIDs).isSubset(of: allowedSources) else {
            throw VoiceOSError("主题骨架缺少有效内容或来源")
        }
        for topic in result.topics {
            guard !topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, topic.title.count <= 200,
                  !topic.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !topic.viewpointIDs.isEmpty, Set(topic.viewpointIDs).count == topic.viewpointIDs.count,
                  topic.viewpointIDs.allSatisfy({ viewpointIDs.contains($0) }),
                  topic.topicID.isEmpty || (seedIDs.contains(topic.topicID) && usedTopicIDs.insert(topic.topicID).inserted) else {
                throw VoiceOSError("主题骨架包含无效观点或重复主题")
            }
            assigned.formUnion(topic.viewpointIDs)
        }
        guard assigned == viewpointIDs else { throw VoiceOSError("主题骨架遗漏了观点，未保存不完整归组") }
    }

    static func body(_ result: TopicBodyResult, input: TopicBodyInput) throws {
        let topics = Dictionary(uniqueKeysWithValues: input.topics.map { ($0.topicID, $0) })
        guard !result.responseID.isEmpty, result.topics.count == topics.count,
              Set(result.topics.map(\.topicID)) == Set(topics.keys) else {
            throw VoiceOSError("主题正文缺少本批主题")
        }
        for proposed in result.topics {
            guard let topic = topics[proposed.topicID] else { throw VoiceOSError("主题正文引用了未知主题") }
            guard !proposed.sections.isEmpty, Set(proposed.sections.map(\.id)).count == proposed.sections.count else {
                throw VoiceOSError("主题正文小节缺失或重复")
            }
            let viewpointIDs = Set(topic.viewpoints.map(\.id)), taskIDs = Set(topic.tasks.map(\.id))
            let sourceIDs = Set(topic.sourceIDs)
            var usedViewpoints = Set<String>(), usedTasks = Set<String>()
            for section in proposed.sections {
                guard !section.id.isEmpty, !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !section.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !section.evidence.isEmpty,
                      Set(section.claimIDs).count == section.claimIDs.count,
                      Set(section.actionIDs).count == section.actionIDs.count else {
                    throw VoiceOSError("主题正文卡片缺少内容或原话依据")
                }
                for evidence in section.evidence {
                    guard sourceIDs.contains(evidence.sourceID),
                          !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw VoiceOSError("主题正文引用了本主题之外的来源")
                    }
                }
                for id in section.claimIDs {
                    guard viewpointIDs.contains(id) else { throw VoiceOSError("主题正文引用了其他主题的观点") }
                    usedViewpoints.insert(id)
                }
                for id in section.actionIDs {
                    guard taskIDs.contains(id) else { throw VoiceOSError("主题正文引用了其他主题的行动") }
                    usedTasks.insert(id)
                }
            }
            guard usedViewpoints == viewpointIDs, usedTasks == taskIDs else {
                throw VoiceOSError("主题正文遗漏了本主题的观点或行动")
            }
        }
    }

    /// Packs topics into batches of at most five, lowering the count whenever
    /// the encoded batch would grow past the target. A single oversized topic
    /// still travels alone so no assignment is silently dropped.
    static func bodyPlans(topics: [TopicBodyTopic]) throws -> [TopicBodyPlan] {
        var plans: [TopicBodyPlan] = [], batch: [TopicBodyTopic] = [], size = 0
        func flush() throws {
            guard !batch.isEmpty else { return }
            let base = TopicBodyInput(digest: "", topics: batch)
            let digest = VoiceOSStore.relevanceHash(Data(try VoiceOSStore.relevanceJSON(TopicBodyDigestInput(version: "topic-body-v1", input: base)).utf8))
            plans.append(TopicBodyPlan(input: .init(digest: digest, topics: batch), scope: batch.map(\.topicID).joined(separator: ",")))
            batch = []; size = 0
        }
        for topic in topics {
            let bytes = (try VoiceOSStore.relevanceJSON(topic)).utf8.count + 128
            if !batch.isEmpty && (batch.count >= TopicOrganizationSlicePolicy.bodyBatchTopicLimit
                || size + bytes > TopicOrganizationSlicePolicy.bodyPackingTarget) {
                try flush()
            }
            batch.append(topic); size += bytes
        }
        try flush()
        return plans
    }
}
