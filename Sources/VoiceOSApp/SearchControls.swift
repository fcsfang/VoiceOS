import Foundation
import SwiftUI
import VoiceOSCore

extension ControlCenter {
    func searchAll(_ query: String) async -> [SearchHit]? {
        guard let store else { status = "资料库尚未打开"; return nil }
        do { return try await store.search(query: query, limit: 60) }
        catch { status = error.localizedDescription; return nil }
    }
}
