import Foundation
import VoiceOSCore

struct WorkspaceSearchResults {
    var hits: [SearchHit]
    var totals: [SearchHit.Kind: Int]
}

extension ControlCenter {
    func searchAll(_ query: String, perKindLimit: Int = 20) async -> WorkspaceSearchResults? {
        guard let store else { status = "资料库尚未打开"; return nil }
        do {
            let results = try await store.searchAll(query: query, perKindLimit: perKindLimit)
            var hits: [SearchHit] = []
            var totals: [SearchHit.Kind: Int] = [:]
            for kind in SearchHit.Kind.allCases {
                hits.append(contentsOf: results.hits(for: kind))
                totals[kind] = results.total(for: kind)
            }
            return WorkspaceSearchResults(hits: hits, totals: totals)
        } catch { status = error.localizedDescription; return nil }
    }
}
