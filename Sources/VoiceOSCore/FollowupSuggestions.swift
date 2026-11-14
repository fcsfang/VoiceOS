import Foundation

public struct FollowupSuggestion: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let prompt: String
    public let claimID: String
    public let sourceTitle: String
}

public enum FollowupSuggestions {
    public static func suggest(claims: [CandidateClaim], sources: [SourceRecord]) -> [FollowupSuggestion] {
        let titles = Dictionary(sources.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        let ranked = claims.enumerated().compactMap { order, claim -> RankedClaim? in
            guard claim.validity == "current", !claim.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let evidence = claim.references.compactMap { reference -> (String, Bool)? in
                guard let title = titles[reference.sourceID], !title.isEmpty else { return nil }
                return (title, !reference.spanID.isEmpty)
            }
            guard let sourceTitle = evidence.first?.0 else { return nil }
            return RankedClaim(claim: claim, sourceTitle: sourceTitle, hasQuote: evidence.contains(where: { $0.1 }), order: order)
        }.sorted { left, right in
            left.hasQuote != right.hasQuote ? left.hasQuote : left.order < right.order
        }
        var kept: [RankedClaim] = []
        for item in ranked {
            guard !kept.contains(where: { similar($0.claim.statement, item.claim.statement) }) else { continue }
            kept.append(item)
            if kept.count == 3 { break }
        }
        guard !kept.isEmpty else { return [] }
        return (0..<min(3, max(2, kept.count))).map { index in
            let angle = Angle.allCases[index % Angle.allCases.count]
            let item = kept[index % kept.count]
            return FollowupSuggestion(id: item.claim.id + ":" + angle.rawValue,
                                      title: angle.title,
                                      prompt: angle.prompt(for: quote(item.claim.statement)),
                                      claimID: item.claim.id,
                                      sourceTitle: item.sourceTitle)
        }
    }

    private struct RankedClaim {
        let claim: CandidateClaim
        let sourceTitle: String
        let hasQuote: Bool
        let order: Int
    }

    private enum Angle: String, CaseIterable {
        case condition, counterexample, nextStep
        var title: String {
            switch self {
            case .condition: return "问成立条件"
            case .counterexample: return "找反例"
            case .nextStep: return "定下一步"
            }
        }
        func prompt(for statement: String) -> String {
            switch self {
            case .condition:
                return "请针对「\(statement)」说明它成立需要哪些条件，并用已有原话说明依据。条件不足时请直接说明，不替我补全。"
            case .counterexample:
                return "请从已有资料为「\(statement)」寻找反例或不同条件，并附原文依据。没有实际反例时请直接说明。可以提出假设情形，但要标为假设。"
            case .nextStep:
                return "请把「\(statement)」整理成一个可验证的下一步：要检验什么、可以怎么做、观察什么结果。结果不支持时请说明怎样修正。不要替我承诺或创建任务。"
            }
        }
    }

    private static func similar(_ left: String, _ right: String) -> Bool {
        let a = normalized(left), b = normalized(right)
        if a == b { return true }
        let short = a.count <= b.count ? a : b
        let long = a.count <= b.count ? b : a
        return short.count >= 8 && long.contains(short)
    }

    private static func normalized(_ statement: String) -> String {
        statement.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func quote(_ statement: String) -> String {
        let flattened = statement.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flattened.count > 60 ? String(flattened.prefix(60)) + "…" : flattened
    }
}
