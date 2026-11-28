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
    func requestMaterialNote(sourceID: String, force: Bool = false, replacingEdited revisionID: String? = nil) async {
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
        let task = Task { await self.runMaterialNoteRequest(sourceID: sourceID, force: force, replacingEdited: revisionID) }
        Self.materialNoteRuns[runKey] = MaterialNoteRun(token: token, force: force, entrySourceID: sourceID, task: task)
        await task.value
        if Self.materialNoteRuns[runKey]?.token == token { Self.materialNoteRuns[runKey] = nil }
    }

    private func runMaterialNoteRequest(sourceID: String, force: Bool, replacingEdited revisionID: String?) async {
        guard let store else { materialNoteStates[sourceID] = .unavailable("资料库尚未打开"); return }
        let memberIDs = materialNoteMemberIDs(sourceID: sourceID)
        do {
            let base = try await store.latestMaterialNote(memberSourceIDs: memberIDs)
            if let base, base.note.manuallyEdited == true, base.id != revisionID {
                materialNoteStates[sourceID] = .idle
                materialNotePresence[sourceID] = true
                return
            }
            guard let port = textModels?.note else { materialNoteStates[sourceID] = .unavailable("文本模型未配置"); return }
            let catalog = Dictionary(try await store.sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let reason = MaterialNoteGating.unavailableReason(memberIDs: memberIDs, catalog: catalog) {
                materialNoteStates[sourceID] = .unavailable(reason)
                return
            }
            let members = memberIDs.compactMap { catalog[$0] }
            let versions = MaterialNoteGating.transcriptVersions(memberIDs: memberIDs, catalog: catalog)
            if !force, let stored = base,
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
            // 板上可引用的行动与观点快照：模型只能引用这些 id，不能发明。
            let memberSet = Set(memberIDs)
            var claimRefs: [NoteBoardClaimRef] = [], seenClaims = Set<String>()
            var allClaims: [String: CandidateClaim] = [:]
            for sourceID in memberIDs {
                for claim in currentClaimsBySource[sourceID] ?? [] {
                    guard claim.validity == "current", claim.reviewState != "rejected", seenClaims.insert(claim.id).inserted else { continue }
                    allClaims[claim.id] = claim
                    claimRefs.append(NoteBoardClaimRef(id: claim.id, statement: claim.statement))
                }
            }
            var seenActions = Set<String>()
            let actionRefs = actionRecords.compactMap { record -> NoteBoardActionRef? in
                guard record.validity == "current", record.state != "dismissed",
                      seenActions.insert(record.id).inserted,
                      let claim = allClaims[record.claimID],
                      !memberSet.isDisjoint(with: Set(claim.references.map(\.sourceID))) else { return nil }
                return NoteBoardActionRef(id: record.id, title: record.title, state: record.state)
            }
            let note = try await port.writeNote(MaterialNoteRequest(members: noteMembers, actions: actionRefs, claims: claimRefs))
            let anchored = MaterialNoteAnchoring.anchored(note, members: noteMembers)
            let identity = port.identity
            // 快照比对与保存同在一个 actor 回合内，校验后到落库之间不会再有
            // 转写或许可变化挤进来。
            let saved = try await store.saveMaterialNote(
                memberSourceIDs: memberIDs, note: anchored, transcriptVersions: versions,
                modelIdentity: identity.provider + " / " + identity.model + " / " + identity.promptVersion + " / " + identity.schemaVersion,
                ifMembersStillMatch: snapshots, replacing: base?.id)
            // 新笔记立刻进入首页缓存，生成后第一次返回首页就能用笔记标题渲染。
            if let saved { materialNoteRows[VoiceOSStore.materialNoteExpressionKey(memberIDs)] = saved }
            if saved != nil { materialNotePresence[sourceID] = true }
            if saved != nil { materialNoteDidSave() }
            materialNoteStates[sourceID] = saved == nil ? .failed("材料在生成期间有变化，请重试") : .idle
        } catch is CancellationError {
            materialNoteStates[sourceID] = .idle
        } catch {
            materialNoteStates[sourceID] = .failed(Self.materialNoteFailureMessage(error))
        }
    }

    /// 笔记首页的批量整理：每份先补做完整转写核对，再生成笔记；单份失败不阻断其余。
    func generateNotesSequentially(_ records: [SourceRecord]) async {
        guard !records.isEmpty else { return }
        guard modelConfigured else { status = "文本模型未配置，无法整理"; return }
        guard !fullRecordingBusy, organizingSourceID == nil else {
            status = "有整理任务正在进行，稍后再试"
            return
        }
        var made = 0, blocked = 0, failed = 0
        for (index, record) in records.enumerated() {
            status = "正在整理第 \(index + 1)/\(records.count) 份：\(record.displayTitle)"
            // 一篇笔记可能由本人录音与配对节目轨共同构成；门控要求每个成员都完成核对，
            // 只核对被选中的本人材料会让配对成员把笔记永远挡在门外。
            var reviewsNeeded: [String] = record.needsTranscriptionReview ? [record.id] : []
            var memberTitles: [String: String] = [record.id: record.displayTitle]
            if let store, let catalog = try? await store.sources() {
                let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let members = materialNoteMemberIDs(sourceID: record.id)
                for memberID in members where memberID != record.id { memberTitles[memberID] = byID[memberID]?.displayTitle }
                reviewsNeeded = members.filter { memberID in
                    memberID == record.id ? record.needsTranscriptionReview : byID[memberID]?.needsTranscriptionReview == true
                }
            }
            if !reviewsNeeded.isEmpty {
                var reviewFailure: String?
                for memberID in reviewsNeeded {
                    let name = memberTitles[memberID] ?? "配对成员"
                    transcriptReviewStatus = "第 \(index + 1)/\(records.count) 份 · 正在核对完整转写：\(name)"
                    do { try await ensureTranscriptReviewed(sourceID: memberID, retry: true) }
                    catch {
                        reviewFailure = "「\(name)」核对未完成：" + error.localizedDescription
                        break
                    }
                }
                if let reviewFailure {
                    failed += 1
                    transcriptReviewStatus = reviewFailure
                    continue
                }
            }
            await requestMaterialNote(sourceID: record.id)
            if let state = materialNoteStates[record.id] {
                switch state {
                case .idle:
                    if materialNotePresence[record.id] == true {
                        made += 1
                        // 生成笔记就是这份材料被处理完：从待处理里移出，下一批继续往前推进。
                        if let store { try? await store.setSourceReadingState(sourceID: record.id, state: .read) }
                    } else { failed += 1 }
                case .unavailable(let reason):
                    blocked += 1
                    status = "「\(record.displayTitle)」暂不能整理：" + reason
                case .generating, .failed:
                    failed += 1
                }
            } else { failed += 1 }
        }
        status = "已整理成笔记 \(made) 份"
            + (blocked > 0 ? "，\(blocked) 份被门控挡住" : "")
            + (failed > 0 ? "，\(failed) 份未完成" : "")
        await refresh()
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
            let catalog = Dictionary(try await store.sourceRecords(ids: memberIDs).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
            let current = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: MaterialNoteGating.transcriptVersions(memberIDs: memberIDs, catalog: catalog))
            return (stored, current)
        } catch { return nil }
    }

    /// 参与一篇笔记的成员：本人各段在前，配对的外部来源（访谈对方/节目轨）
/// 按 sourceID 排序随后；与表达级讨论、知识核查的展开口径一致。
    func materialNoteMemberIDs(sourceID: String) -> [String] {
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
