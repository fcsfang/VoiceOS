import VoiceOSCore

extension ControlCenter {
    func readingStates() async -> [String: SourceReadingState] {
        guard let store else { status = "资料库尚未打开"; return [:] }
        do { return try await store.sourceReadingStates() }
        catch { status = error.localizedDescription; return [:] }
    }

    func setReadingState(sourceID: String, state: SourceReadingState) async -> Bool {
        guard let store else { status = "资料库尚未打开"; return false }
        do {
            try await store.setSourceReadingState(sourceID: sourceID, state: state)
            return true
        } catch { status = error.localizedDescription; return false }
    }
}
