import Foundation
import VoiceOSCore

struct WorkspaceSearchResults {
    var hits: [SearchHit]
    var totals: [SearchHit.Kind: Int]
}

extension ControlCenter {
    /// Unit I defines `VoiceOSStore.searchAll(query:perKindLimit:)` and returns
    /// per-kind capped hits plus per-kind totals. If its result names the two
    /// members differently, only this adapter changes.
    func searchAll(_ query: String, perKindLimit: Int = 20) async -> WorkspaceSearchResults? {
        guard let store else { status = "资料库尚未打开"; return nil }
        do {
            let results = try await store.searchAll(query: query, perKindLimit: perKindLimit)
            return WorkspaceSearchResults(hits: results.hits, totals: results.totals)
        } catch { status = error.localizedDescription; return nil }
    }
}
