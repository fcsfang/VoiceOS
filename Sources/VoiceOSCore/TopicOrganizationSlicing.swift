import Foundation

/// The model-facing stages of topic organization. Skeleton batches see
/// viewpoints only, the merge sees candidate titles and viewpoint ids only, and
/// each body batch sees the statements and short verbatim quotes of the topics
/// assigned to it. Full transcripts stay local.
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
    /// 人生维度（TopicDomain 的 rawValue）；旧结果没有这个字段，解码为 nil。
    public var domain: String? = nil
    public let viewpointIDs: [String]
    public init(topicID: String, title: String, summary: String, questions: [String]? = nil,
                domain: String? = nil, viewpointIDs: [String]) {
        self.topicID = topicID; self.title = title; self.summary = summary
        self.questions = questions; self.domain = domain; self.viewpointIDs = viewpointIDs
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

/// A merge candidate carries ids only: the merge request sees titles, summaries
/// and the viewpoints they cover, never statements or transcripts.
public struct TopicSkeletonMergeCandidate: Codable, Sendable {
    public let topicID: String
    public let title: String
    public let summary: String
    public let viewpointIDs: [String]
    public init(topicID: String, title: String, summary: String, viewpointIDs: [String]) {
        self.topicID = topicID; self.title = title; self.summary = summary; self.viewpointIDs = viewpointIDs
    }
}

public struct TopicSkeletonMergeBatch: Codable, Sendable {
    /// Every viewpoint id of the batch; the merged topics must draw from these.
    public let viewpointIDs: [String]
    public let topics: [TopicSkeletonMergeCandidate]
    public init(viewpointIDs: [String], topics: [TopicSkeletonMergeCandidate]) {
        self.viewpointIDs = viewpointIDs; self.topics = topics
    }
}

public struct TopicSkeletonMergeInput: Codable, Sendable {
    public let digest: String
    public let batches: [TopicSkeletonMergeBatch]
    public init(digest: String, batches: [TopicSkeletonMergeBatch]) { self.digest = digest; self.batches = batches }
}

public struct TopicSkeletonMergeResult: Codable, Sendable {
    public let briefing: String
    public let topics: [TopicSkeletonTopic]
    public let responseID: String
    public init(briefing: String, topics: [TopicSkeletonTopic], responseID: String) {
        self.briefing = briefing; self.topics = topics; self.responseID = responseID
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

/// Some stages may finish while others fail. Completed stages stay readable and
/// resumable; the caller reports how many still need a top-up.
public struct TopicOrganizationIncomplete: Error, Sendable, LocalizedError, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case topics
        case skeletonBatches
    }
    public let kind: Kind
    public let count: Int
    public let firstReason: String
    public init(topicCount: Int, firstReason: String) {
        kind = .topics; count = topicCount; self.firstReason = firstReason
    }
    public init(skeletonBatchCount: Int, firstReason: String) {
        kind = .skeletonBatches; count = skeletonBatchCount; self.firstReason = firstReason
    }
    /// Body failures count topics; skeleton failures count batches.
    public var topicCount: Int { count }
    public var errorDescription: String? {
        let suffix = firstReason.isEmpty ? "" : "。最近原因：" + firstReason
        switch kind {
        case .topics: return "\(count) 个主题待补齐；已完成的主题会保留，可稍后补齐" + suffix
        case .skeletonBatches: return "\(count) 批观点待重新归组；已完成的批次会保留，可稍后补齐" + suffix
        }
    }
}

/// A skeleton batch whose output was cut off by the response limit. A longer
/// transport deadline cannot help; the batch itself must shrink.
public struct TopicSkeletonTruncated: Error, Sendable, LocalizedError, Equatable {
    public let viewpointCount: Int
    public init(viewpointCount: Int) { self.viewpointCount = viewpointCount }
    public var errorDescription: String? {
        "单批观点过多，需要更小批次（本批 \(viewpointCount) 个观点）；本次输出被截断，未保存部分归组"
    }
}

/// Knowledge or tasks changed between stages; the run must restart on the new
/// input instead of filing a batch failure.
struct TopicOrganizationInputChanged: Error, Sendable, LocalizedError {
    var errorDescription: String? { "资料或任务已变化，将基于当前内容重新归组" }
}

struct TopicBodyPlan: Sendable {
    let input: TopicBodyInput
    let scope: String
    var digest: String { input.digest }
}

struct TopicSkeletonBatchPlan: Sendable {
    let input: TopicSkeletonInput
    let scope: String
    var digest: String { input.digest }
}

struct TopicSkeletonBatchOutcome: Sendable {
    let plan: TopicSkeletonBatchPlan
    let result: TopicSkeletonResult
}

/// One skeleton request per viewpoint batch; the merge over their candidates is
/// the only request that sees every group at once. Both stage kinds are
/// replayable by digest, and a merge that drops viewpoints is repaired by one
/// more skeleton request per affected batch.
enum TopicSkeletonBatching {
    static func plans(viewpoints: [TopicSkeletonViewpoint], seeds: [TopicSkeletonTopicSeed],
                      manualTopics: [TopicSkeletonTopicSeed]) throws -> [TopicSkeletonBatchPlan] {
        let sorted = viewpoints.sorted { $0.id < $1.id }
        var plans: [TopicSkeletonBatchPlan] = []
        var start = 0
        while start < sorted.count {
            let end = min(start + TopicOrganizationSlicePolicy.skeletonBatchViewpointLimit, sorted.count)
            let batch = Array(sorted[start..<end])
            let digest = VoiceOSStore.relevanceHash(Data(try VoiceOSStore.relevanceJSON(
                TopicSkeletonDigestInput(version: "topic-skeleton-v1", viewpoints: batch, manualTopics: manualTopics)).utf8))
            plans.append(.init(input: .init(digest: digest, topics: seeds, viewpoints: batch),
                               scope: batch.map(\.id).joined(separator: ",")))
            start = end
        }
        return plans
    }

    static func mergeInput(_ outcomes: [TopicSkeletonBatchOutcome]) throws -> TopicSkeletonMergeInput {
        let batches = outcomes.map { outcome in
            TopicSkeletonMergeBatch(
                viewpointIDs: outcome.plan.input.viewpoints.map(\.id),
                topics: outcome.result.topics.map {
                    TopicSkeletonMergeCandidate(topicID: $0.topicID, title: $0.title, summary: $0.summary,
                                                viewpointIDs: $0.viewpointIDs)
                })
        }
        let base = TopicSkeletonMergeInput(digest: "", batches: batches)
        let digest = VoiceOSStore.relevanceHash(Data(try VoiceOSStore.relevanceJSON(
            TopicSkeletonMergeDigestInput(version: "topic-skeleton-merge-v1", input: base)).utf8))
        return .init(digest: digest, batches: batches)
    }

    static func missingViewpoints(_ result: TopicSkeletonMergeResult, outcomes: [TopicSkeletonBatchOutcome]) -> Set<String> {
        let all = Set(outcomes.flatMap { $0.plan.input.viewpoints.map(\.id) })
        let covered = Set(result.topics.flatMap(\.viewpointIDs))
        return all.subtracting(covered)
    }

    static func assembledSkeleton(_ merge: TopicSkeletonMergeResult, outcomes: [TopicSkeletonBatchOutcome]) -> TopicSkeletonResult {
        var highlights: [String] = [], seen = Set<String>()
        for outcome in outcomes {
            for sourceID in outcome.result.highlightSourceIDs where seen.insert(sourceID).inserted {
                highlights.append(sourceID)
            }
        }
        return .init(briefing: merge.briefing, highlightSourceIDs: highlights, topics: merge.topics, responseID: merge.responseID)
    }
}

struct TopicSkeletonDigestInput: Encodable {
    let version: String
    let viewpoints: [TopicSkeletonViewpoint]
    let manualTopics: [TopicSkeletonTopicSeed]
}

struct TopicSkeletonMergeDigestInput: Encodable {
    let version: String
    let input: TopicSkeletonMergeInput
}

struct TopicBodyDigestInput: Encodable {
    let version: String
    let input: TopicBodyInput
}

enum TopicOrganizationSlicePolicy {
    static let skeletonByteLimit = 120 * 1024
    static let skeletonBatchViewpointLimit = 150
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

    /// The merge keeps every final topic inside the ids its batches sent. Full
    /// coverage is the store's check, because only it can refill a gap by
    /// re-requesting the batch that owns the missing viewpoints.
    static func skeletonMerge(_ result: TopicSkeletonMergeResult, input: TopicSkeletonMergeInput) throws {
        let viewpointIDs = Set(input.batches.flatMap(\.viewpointIDs))
        let seedIDs = Set(input.batches.flatMap { $0.topics.map(\.topicID) }.filter { !$0.isEmpty })
        var usedTopicIDs = Set<String>()
        guard !result.responseID.isEmpty, !result.topics.isEmpty,
              !result.briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("主题骨架合流缺少有效内容")
        }
        for topic in result.topics {
            guard !topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, topic.title.count <= 200,
                  !topic.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !topic.viewpointIDs.isEmpty, Set(topic.viewpointIDs).count == topic.viewpointIDs.count,
                  topic.viewpointIDs.allSatisfy({ viewpointIDs.contains($0) }),
                  topic.topicID.isEmpty || (seedIDs.contains(topic.topicID) && usedTopicIDs.insert(topic.topicID).inserted) else {
                throw VoiceOSError("主题骨架合流包含无效观点或重复主题")
            }
        }
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
