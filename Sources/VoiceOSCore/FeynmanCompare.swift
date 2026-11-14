import Foundation

public struct FeynmanFeedback: Equatable, Sendable {
    public let covered: [String]
    public let missed: [String]
    public let vague: String?

    public init(covered: [String], missed: [String], vague: String?) {
        self.covered = covered
        self.missed = missed
        self.vague = vague
    }
}

public enum FeynmanCompare {
    static let vagueHint = "复述偏短，与原话重合的词也不多。可以再具体一点，然后重新对照。"

    public static func compare(claim: String, response: String) -> FeynmanFeedback {
        let claimTokens = uniqueTokens(claim)
        guard !claimTokens.isEmpty else {
            return FeynmanFeedback(covered: [], missed: [], vague: nil)
        }
        let responseTokens = Set(tokens(response))
        let covered = claimTokens.filter { responseTokens.contains($0) }
        let missed = claimTokens.filter { !responseTokens.contains($0) }
        let coverage = Double(covered.count) / Double(claimTokens.count)
        let short = Double(response.trimmingCharacters(in: .whitespacesAndNewlines).count)
            < Double(claim.trimmingCharacters(in: .whitespacesAndNewlines).count) * 0.3
        return FeynmanFeedback(covered: Array(covered.prefix(6)),
                               missed: Array(missed.prefix(6)),
                               vague: short || coverage < 0.3 ? vagueHint : nil)
    }

    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var han: [Character] = []
        var word = ""
        func flushHan() {
            if han.count == 1 {
                result.append(String(han[0]))
            } else if han.count > 1 {
                for index in 0..<(han.count - 1) {
                    result.append(String(han[index...index + 1]))
                }
            }
            han.removeAll()
        }
        func flushWord() {
            if !word.isEmpty { result.append(word.lowercased()) }
            word.removeAll()
        }
        for character in text {
            if isHan(character) {
                flushWord()
                han.append(character)
            } else if character.isLetter || character.isNumber {
                flushHan()
                word.append(character)
            } else {
                flushWord()
            }
        }
        flushHan()
        flushWord()
        return result
    }

    static func uniqueTokens(_ text: String) -> [String] {
        var seen: Set<String> = []
        return tokens(text).filter { seen.insert($0).inserted }
    }

    private static func isHan(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic
    }
}
