import Foundation
import VoiceOSCore

struct SourceOutlineSection:Identifiable {
    let id:Int
    let startMS:Int
    let endMS:Int
    let title:String
}

enum SourceText {
    static func quote(_ span:TranscriptSpan,in text:String) -> String {
        let scalars=Array(text.unicodeScalars)
        guard span.textStart>=0,span.textEnd<=scalars.count,span.textStart<=span.textEnd else { return "原文范围已变化" }
        return String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
    }
}

enum SourceOutline {
    static let gapMS=20_000
    static let maxSections=20

    static func sections(spans:[TranscriptSpan],transcript:String) -> [SourceOutlineSection] {
        let timed=spans.compactMap { span -> (span:TranscriptSpan,start:Int,end:Int)? in
            guard let start=span.startMS,let end=span.endMS else { return nil }
            return (span,start,end)
        }.sorted { $0.start < $1.start }
        guard !timed.isEmpty else { return [] }
        var groups:[[(span:TranscriptSpan,start:Int,end:Int)]]=[]
        var current:[(span:TranscriptSpan,start:Int,end:Int)]=[]
        for item in timed {
            if let previous=current.last,item.start - previous.end > gapMS {
                groups.append(current)
                current=[]
            }
            current.append(item)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.prefix(maxSections).enumerated().map { index,group in
            let first=group[0]
            return SourceOutlineSection(id:index,startMS:first.start,endMS:group.map { $0.end }.max() ?? first.end,title:title(for:first.span,in:transcript))
        }
    }

    private static func title(for span:TranscriptSpan,in transcript:String) -> String {
        let cleaned=SourceText.quote(span,in:transcript).components(separatedBy:.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator:" ")
        guard !cleaned.isEmpty else { return "" }
        let prefix=String(cleaned.prefix(24))
        return prefix.count < cleaned.count ? prefix + "…" : prefix
    }
}

struct ReadingDigest {
    let excerpt:String?
    let points:[String]
    let sentence:String?
    var isEmpty:Bool { excerpt == nil && points.isEmpty && sentence == nil }
}

enum ReadingLayers {
    static func digest(transcript:String?,thoughts:[CandidateClaim],summary:String?) -> ReadingDigest {
        ReadingDigest(excerpt:excerpt(transcript),points:thoughts.compactMap { firstSentence($0.statement) },sentence:summary.flatMap(firstSentence))
    }

    static func excerpt(_ transcript:String?,limit:Int=120) -> String? {
        guard let transcript else { return nil }
        let cleaned=transcript.components(separatedBy:.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator:" ")
        guard !cleaned.isEmpty else { return nil }
        let prefix=String(cleaned.prefix(limit))
        return prefix.count < cleaned.count ? prefix + "…" : prefix
    }

    static func firstSentence(_ text:String) -> String? {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var result=""
        for character in trimmed {
            if character.isNewline { break }
            result.append(character)
            if "。！？!?".contains(character) { break }
        }
        return result.trimmingCharacters(in:.whitespaces)
    }
}
