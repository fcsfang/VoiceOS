import Foundation
import VoiceOSCore

/// Note generation state for one entry material, read by the material page.
enum MaterialNoteState: Equatable {
    case idle
    case unavailable(String)
    case generating
    case failed(String)
}

/// One generation run per expression; owning the registry entry means owning
/// the state writes for that source, so a vanished view cannot strand it.
struct MaterialNoteRun {
    let token: UUID
    let force: Bool
    let task: Task<Void, Never>
}

/// One expression's note: readiness and permission gates, one in-flight
/// attempt per entry material, and a stale-result guard keyed on the member
/// transcript versions and policy versions captured before the model call.
extension ControlCenter {
    /// Concurrent callers join the run in flight instead of starting a second
    /// model call. A forced request that joined a non-forced run starts its
    /// own run once that run finishes.
    func requestMaterialNote(sourceID: String, force: Bool = false) async {
        if let run = Self.materialNoteRuns[sourceID] {
            await run.task.value
            guard !Task.isCancelled else { return }
            guard force, !run.force else { return }
            guard Self.materialNoteRuns[sourceID] == nil else { return }
        }
        guard !Task.isCancelled else { return }
        let token = UUID()
        let task = Task { await self.runMaterialNoteRequest(sourceID: sourceID, force: force) }
        Self.materialNoteRuns[sourceID] = MaterialNoteRun(token: token, force: force, task: task)
        await task.value
        if Self.materialNoteRuns[sourceID]?.token == token { Self.materialNoteRuns[sourceID] = nil }
    }

    private func runMaterialNoteRequest(sourceID: String, force: Bool) async {
        guard let store else { materialNoteStates[sourceID] = .unavailable("资料库尚未打开"); return }
        guard let port = materialNoteModel else { materialNoteStates[sourceID] = .unavailable("文本模型未配置"); return }
        // 在任何 await 之前同步占据该表达，后续并发请求只能加入本次运行。
        materialNoteStates[sourceID] = .generating
        let memberIDs = sourcePageIndex.expression(for: sourceID)?.sourceIDs ?? [sourceID]
        do {
            let catalog = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let reason = MaterialNoteGating.unavailableReason(memberIDs: memberIDs, catalog: catalog) {
                materialNoteStates[sourceID] = .unavailable(reason)
                return
            }
            let members = memberIDs.compactMap { catalog[$0] }
            let versions = MaterialNoteGating.transcriptVersions(memberIDs: memberIDs, catalog: catalog)
            if !force, let stored = try await store.latestMaterialNote(memberSourceIDs: memberIDs),
               await store.materialNoteIsCurrent(stored, currentTranscriptVersions: versions) {
                materialNoteStates[sourceID] = .idle
                return
            }
            let snapshots = members.map(MaterialNoteMemberSnapshot.init)
            let noteMembers = members.map { record in
                MaterialNoteMember(sourceID: record.id, title: record.displayTitle,
                                   transcriptVersionID: record.transcriptVersionID,
                                   transcript: record.transcript ?? "",
                                   spans: materialNoteSpans(for: record))
            }
            let note = try await port.writeNote(MaterialNoteRequest(members: noteMembers))
            let anchored = MaterialNoteAnchoring.anchored(note, members: noteMembers)
            let identity = port.identity
            // 快照比对与保存同在一个 actor 回合内，校验后到落库之间不会再有
            // 转写或许可变化挤进来。
            let saved = try await store.saveMaterialNote(
                memberSourceIDs: memberIDs, note: anchored, transcriptVersions: versions,
                modelIdentity: identity.provider + " / " + identity.model + " / " + identity.promptVersion + " / " + identity.schemaVersion,
                ifMembersStillMatch: snapshots)
            materialNoteStates[sourceID] = saved == nil ? .failed("材料在生成期间有变化，请重试") : .idle
        } catch is CancellationError {
            materialNoteStates[sourceID] = .idle
        } catch {
            materialNoteStates[sourceID] = .failed(Self.materialNoteFailureMessage(error))
        }
    }

    @MainActor private static var materialNoteRuns: [String: MaterialNoteRun] = [:]

    /// The newest saved note for the expression that contains this material,
    /// with currentness judged against the member versions in the library now.
    func materialNoteForDisplay(sourceID: String) async -> (note: StoredMaterialNote, isCurrent: Bool)? {
        guard let store else { return nil }
        let memberIDs = sourcePageIndex.expression(for: sourceID)?.sourceIDs ?? [sourceID]
        do {
            guard let stored = try await store.latestMaterialNote(memberSourceIDs: memberIDs) else { return nil }
            let catalog = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let current = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: MaterialNoteGating.transcriptVersions(memberIDs: memberIDs, catalog: catalog))
            return (stored, current)
        } catch { return nil }
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