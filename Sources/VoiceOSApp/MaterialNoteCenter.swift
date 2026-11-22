import Foundation
import VoiceOSCore

/// Note generation state for one entry material, read by the material page.
enum MaterialNoteState: Equatable {
    case idle
    case unavailable(String)
    case generating
    case failed(String)
}

/// One expression's note: readiness and permission gates, one in-flight
/// attempt per entry material, and a stale-result guard keyed on the member
/// transcript versions and policy versions captured before the model call.
extension ControlCenter {
    func requestMaterialNote(sourceID: String, force: Bool = false) async {
        if materialNoteStates[sourceID] == .generating { return }
        guard let store else { materialNoteStates[sourceID] = .unavailable("资料库尚未打开"); return }
        guard let port = materialNoteModel else { materialNoteStates[sourceID] = .unavailable("文本模型未配置"); return }
        let memberIDs = sourcePageIndex.expression(for: sourceID)?.sourceIDs ?? [sourceID]
        do {
            let catalog = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let reason = materialNoteUnavailableReason(memberIDs: memberIDs, catalog: catalog) {
                materialNoteStates[sourceID] = .unavailable(reason)
                return
            }
            let members = memberIDs.compactMap { catalog[$0] }
            let versions = materialNoteTranscriptVersions(memberIDs: memberIDs, catalog: catalog)
            if !force, let stored = try await store.latestMaterialNote(memberSourceIDs: memberIDs),
               await store.materialNoteIsCurrent(stored, currentTranscriptVersions: versions) {
                materialNoteStates[sourceID] = .idle
                return
            }
            materialNoteStates[sourceID] = .generating
            let snapshots = members.map(MaterialNoteMemberSnapshot.init)
            let noteMembers = members.map { record in
                MaterialNoteMember(sourceID: record.id, title: record.displayTitle,
                                   transcriptVersionID: record.transcriptVersionID,
                                   transcript: record.transcript ?? "",
                                   spans: materialNoteSpans(for: record))
            }
            let note = try await port.writeNote(MaterialNoteRequest(members: noteMembers))
            let anchored = MaterialNoteAnchoring.anchored(note, members: noteMembers)
            let fresh = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard snapshots.allSatisfy({ $0.matches(fresh[$0.sourceID]) }) else {
                materialNoteStates[sourceID] = .failed("材料在生成期间有变化，请重试")
                return
            }
            let identity = port.identity
            try await store.saveMaterialNote(memberSourceIDs: memberIDs, note: anchored,
                                             transcriptVersions: versions,
                                             modelIdentity: identity.provider + " / " + identity.model + " / " + identity.promptVersion + " / " + identity.schemaVersion)
            materialNoteStates[sourceID] = .idle
        } catch is CancellationError {
            materialNoteStates[sourceID] = .idle
        } catch {
            materialNoteStates[sourceID] = .failed(Self.materialNoteFailureMessage(error))
        }
    }

    /// The newest saved note for the expression that contains this material,
    /// with currentness judged against the member versions in the library now.
    func materialNoteForDisplay(sourceID: String) async -> (note: StoredMaterialNote, isCurrent: Bool)? {
        guard let store else { return nil }
        let memberIDs = sourcePageIndex.expression(for: sourceID)?.sourceIDs ?? [sourceID]
        do {
            guard let stored = try await store.latestMaterialNote(memberSourceIDs: memberIDs) else { return nil }
            let catalog = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let current = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: materialNoteTranscriptVersions(memberIDs: memberIDs, catalog: catalog))
            return (stored, current)
        } catch { return nil }
    }

    private func materialNoteUnavailableReason(memberIDs: [String], catalog: [String: SourceRecord]) -> String? {
        for id in memberIDs {
            guard let record = catalog[id] else { return "材料已变化或已移出资料库" }
            guard ["saved", "reference_only"].contains(record.state) else { return "材料尚未保存完成" }
            guard !record.localOnly else { return "仅本机保存" }
            guard let transcript = record.transcript,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.transcriptVersionID != nil else { return "尚无转写" }
        }
        return nil
    }

    private func materialNoteTranscriptVersions(memberIDs: [String], catalog: [String: SourceRecord]) -> [String: String] {
        var versions: [String: String] = [:]
        for id in memberIDs {
            if let version = catalog[id]?.transcriptVersionID { versions[id] = version }
        }
        return versions
    }

    private func materialNoteSpans(for record: SourceRecord) -> [MaterialNoteSpan] {
        guard let transcript = record.transcript else { return [] }
        let scalars = Array(transcript.unicodeScalars)
        return record.spans.compactMap { span in
            guard span.textStart >= 0, span.textStart < span.textEnd, span.textEnd <= scalars.count else { return nil }
            return MaterialNoteSpan(id: span.id, startMS: span.startMS, endMS: span.endMS,
                                    text: String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])))
        }
    }

    private static func materialNoteFailureMessage(_ error: Error) -> String {
        if case ModelPortFailure.rejected(let reason, _, _) = error { return reason }
        return error.localizedDescription
    }
}

private struct MaterialNoteMemberSnapshot {
    let sourceID: String
    let transcriptVersionID: String?
    let policyVersion: Int
    let localOnly: Bool
    let state: String

    init(_ record: SourceRecord) {
        sourceID = record.id
        transcriptVersionID = record.transcriptVersionID
        policyVersion = record.policyVersion
        localOnly = record.localOnly
        state = record.state
    }

    func matches(_ record: SourceRecord?) -> Bool {
        guard let record else { return false }
        return record.state == state && record.transcriptVersionID == transcriptVersionID &&
            record.policyVersion == policyVersion && record.localOnly == localOnly &&
            ["saved", "reference_only"].contains(record.state)
    }
}