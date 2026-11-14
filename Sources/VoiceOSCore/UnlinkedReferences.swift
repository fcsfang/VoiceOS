import Foundation

public enum UnlinkedReferences {
    public static func candidates(
        topicTitle: String,
        sectionTitles: [String],
        linkedClaimIDs: Set<String>,
        topicSourceIDs: Set<String>,
        claims: [CandidateClaim]
    ) -> [CandidateClaim] {
        let words = topicWords(topicTitle: topicTitle, sectionTitles: sectionTitles)
        guard !words.isEmpty, !topicSourceIDs.isEmpty else { return [] }
        let ranked = claims.compactMap { claim -> Ranked? in
            guard claim.validity == "current", claim.reviewState != "rejected",
                  !linkedClaimIDs.contains(claim.id),
                  let sourceID = claim.references.map(\.sourceID).first(where: topicSourceIDs.contains) else { return nil }
            let hits = words.filter { matches($0, statement: claim.statement) }.count
            return hits > 0 ? Ranked(claim: claim, hits: hits, sourceID: sourceID) : nil
        }.sorted {
            if $0.hits != $1.hits { return $0.hits > $1.hits }
            if $0.claim.statement.count != $1.claim.statement.count { return $0.claim.statement.count < $1.claim.statement.count }
            return $0.claim.id < $1.claim.id
        }
        var perSource: [String: Int] = [:]
        var result: [CandidateClaim] = []
        for entry in ranked {
            guard result.count < 5 else { break }
            let count = perSource[entry.sourceID, default: 0]
            guard count < 3 else { continue }
            perSource[entry.sourceID] = count + 1
            result.append(entry.claim)
        }
        return result
    }

    private struct Ranked {
        let claim: CandidateClaim
        let hits: Int
        let sourceID: String
    }

    private struct TopicWord {
        let text: String
        let isEnglish: Bool
    }

    private static let titleSeparators: Set<Character> = ["、", "与", "和", "及", "/"]

    private static func topicWords(topicTitle: String, sectionTitles: [String]) -> [TopicWord] {
        var seen = Set<String>()
        var words: [TopicWord] = []
        for title in [topicTitle] + sectionTitles {
            for fragment in title.split(whereSeparator: { titleSeparators.contains($0) }) {
                let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard trimmed.count >= 2 else { continue }
                if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    for word in trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                        let text = word.lowercased()
                        guard !text.isEmpty, seen.insert("en:" + text).inserted else { continue }
                        words.append(TopicWord(text: text, isEnglish: true))
                    }
                } else if seen.insert("zh:" + trimmed).inserted {
                    words.append(TopicWord(text: trimmed, isEnglish: false))
                }
            }
        }
        return words
    }

    private static func matches(_ word: TopicWord, statement: String) -> Bool {
        if !word.isEnglish { return statement.contains(word.text) }
        return statement.split(whereSeparator: { !$0.isASCII || (!$0.isLetter && !$0.isNumber) })
            .contains { $0.lowercased() == word.text }
    }
}
