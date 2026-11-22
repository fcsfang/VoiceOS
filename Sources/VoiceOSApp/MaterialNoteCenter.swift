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
    let entrySourceID: String
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
        // 单飞按「一篇笔记」键控：同一表达从任一分段进入都加入同一次运行。
        let runKey = materialNoteMemberIDs(sourceID: sourceID).sorted().joined(separator: "|")
        if let run = Self.materialNoteRuns[runKey] {
            await run.task.value
            guard !Task.isCancelled else { return }
            if run.entrySourceID != sourceID, let state = materialNoteStates[run.entrySourceID] {
                materialNoteStates[sourceID] = state
            }
            guard force, !run.force else { return }
            guard Self.materialNoteRuns[runKey] == nil else { return }
        }
        guard !Task.isCancelled else { return }
        let token = UUID()
        let task = Task { await self.runMaterialNoteRequest(sourceID: sourceID, force: force) }
        Self.materialNoteRuns[runKey] = MaterialNoteRun(token: token, force: force, entrySourceID: sourceID, task: task)
        await task.value
        if Self.materialNoteRuns[runKey]?.token == token { Self.materialNoteRuns[runKey] = nil }
    }

    private func runMaterialNoteRequest(sourceID: String, force: Bool) async {
        guard let store else { materialNoteStates[sourceID] = .unavailable("资料库尚未打开"); return }
        guard let port = materialNoteModel else { materialNoteStates[sourceID] = .unavailable("文本模型未配置"); return }
        let memberIDs = materialNoteMemberIDs(sourceID: sourceID)
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
                materialNotePresence[sourceID] = true
                return
            }
            // 单飞已由 run 注册表保证；确认确实需要生成后才进入 generating，
            // 打开已有笔记的材料不再先闪一次生成态。
            materialNoteStates[sourceID] = .generating
            let snapshots = members.map(MaterialNoteMemberSnapshot.init)
            let noteMembers = members.map { record in
                MaterialNoteMember(sourceID: record.id, title: record.displayTitle,
                                   transcriptVersionID: record.transcriptVersionID,
                                   transcript: record.transcript ?? "",
                                   spans: materialNoteSpans(for: record),
                                   origin: record.origin, speaker: record.speaker)
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
            // 新笔记立刻进入首页缓存，生成后第一次返回首页就能用笔记标题渲染。
            if let saved { materialNoteRows[VoiceOSStore.materialNoteExpressionKey(memberIDs)] = saved }
            materialNotePresence[sourceID] = saved != nil
            if saved != nil { materialNoteDidSave() }
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
        let memberIDs = materialNoteMemberIDs(sourceID: sourceID)
        do {
            guard let stored = try await store.latestMaterialNote(memberSourceIDs: memberIDs) else {
                materialNotePresence[sourceID] = false
                return nil
            }
            materialNotePresence[sourceID] = true
            materialNoteRows[VoiceOSStore.materialNoteExpressionKey(memberIDs)] = stored
            let catalog = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let current = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: MaterialNoteGating.transcriptVersions(memberIDs: memberIDs, catalog: catalog))
            return (stored, current)
        } catch { return nil }
    }

    /// 参与一篇笔记的成员：本人各段在前，配对的外部来源（访谈对方/节目轨）
/// 按 sourceID 排序随后；与表达级讨论、知识核查的展开口径一致。
    private func materialNoteMemberIDs(sourceID: String) -> [String] {
        guard let expression = sourcePageIndex.expression(for: sourceID) else { return [sourceID] }
        let external = (expression.externalVersions ?? [:]).keys.sorted()
        return expression.sourceIDs + external.filter { !expression.sourceIDs.contains($0) }
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