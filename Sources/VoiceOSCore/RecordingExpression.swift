import Foundation

public struct AutomaticRecordingInput: Codable, Sendable {
    public let inbox: String
    public let recordedAt: String?
    public let discoveredAt: String
}
public struct RecordingExpression: Codable, Sendable, Identifiable {
    public let id: String
    public let sourceIDs: [String]
    public let title: String
    public let summary: String
    public let reason: String
    public let responseIDs: [String]
    public let versions: [String: String]
    public let policies: [String: Int]
    public var state: String
    public var previousActionIDs: [String]
    public var actionReviewResponseIDs: [String]? = nil
    public var actionReviewDecisions: [RecordingExpressionActionDecision]? = nil
    public var reminderUpdates: [String]? = nil
    public var taskReviewPending: Bool? = nil
    public var externalVersions: [String:String]? = nil
    public var externalPolicies: [String:Int]? = nil
    public var manualTitle: String? = nil
    public func requiresActionReview(actionID:String) -> Bool {
        guard state == "completed" else { return true }
        guard let decisions=actionReviewDecisions else { return taskReviewPending == true }
        let uncertain=decisions.filter { $0.relation == "uncertain" }
        guard uncertain.allSatisfy({ $0.possibleNewIDs != nil }) else { return true }
        let possible=Set(uncertain.flatMap { $0.possibleNewIDs ?? [] })
        return uncertain.contains { $0.oldID == actionID } || possible.contains(actionID) ||
            decisions.contains { $0.relation == "same" && $0.oldID == actionID && possible.contains($0.newID) }
    }
    public var digest: String { VoiceOSStore.relevanceHash(Data((sourceIDs.map { $0+":"+(versions[$0] ?? "") } + (externalVersions ?? [:]).keys.sorted().map { $0+":"+(externalVersions?[$0] ?? "") }).joined(separator:"\n").utf8)) }
}
enum RecordingExpressionInvalidity: Error {
    case sourceChanged
    case missingMember
    case memberChanged
    case pairedContextChanged
    case externalChanged

    var message: String {
        switch self {
        case .sourceChanged: "这段原文或文字授权已变化"
        case .missingMember: "分组里有一段录音已不在资料库"
        case .memberChanged: "分组里有一段的原文或文字授权已变化"
        case .pairedContextChanged: "节目背景或原文授权已变化"
        case .externalChanged: "节目原文或文字授权已变化"
        }
    }
}

extension RecordingSourceFacts {
    var readableRecordingExpression: RecordingExpression? {
        guard let expression = presentation?.expression, !localOnly, !needsTranscriptionReview,
              expression.versions[id] == recordingTranscriptVersionID,
              expression.policies[id] == policyVersion else { return nil }
        return expression
    }
}

extension RecordingExpression {
    static func current(in catalog: [String: SourceRecord]) -> [RecordingExpression] {
        var seen = Set<String>()
        return catalog.values.compactMap { source in
            guard let expression = source.presentation?.expression,
                  seen.insert(expression.id).inserted,
                  expression.invalidity(in: catalog, for: .workflow) == nil else { return nil }
            return expression
        }.sorted { $0.id < $1.id }
    }

    enum Use {
        // The reader uses each member's readable revision and the group digest.
        case reading
        // Workflow commands use the saved group identity and captured versions.
        case workflow
    }

    func invalidity<Source: RecordingSourceFacts>(in catalog: [String: Source], for use: Use) -> RecordingExpressionInvalidity? {
        let readingDigest = use == .reading ? digest : nil
        for sourceID in sourceIDs {
            guard let member = catalog[sourceID] else { return .missingMember }
            switch use {
            case .reading:
                guard let expression = member.readableRecordingExpression,
                      expression.digest == readingDigest else { return .memberChanged }
            case .workflow:
                guard member.presentation?.expression?.id == id,
                      member.recordingTranscriptVersionID == versions[sourceID],
                      member.policyVersion == policies[sourceID],
                      !member.localOnly, member.state == "saved" else { return .memberChanged }
            }
            if let pair = member.presentation?.recordingContext {
                guard externalVersions?[pair.externalSourceID] == pair.externalVersionID,
                      externalPolicies?[pair.externalSourceID] == pair.externalPolicyVersion else { return .pairedContextChanged }
            }
        }
        for (sourceID, version) in externalVersions ?? [:] {
            guard let external = catalog[sourceID],
                  external.recordingTranscriptVersionID == version,
                  external.policyVersion == externalPolicies?[sourceID],
                  !external.localOnly, !external.needsTranscriptionReview else { return .externalChanged }
        }
        return nil
    }
}

public struct RecordingExpressionProposal: Codable, Sendable {
    public let existingID: String
    public let sourceIDs: [String]
    public let title: String
    public let summary: String
    public let reason: String
    public let evidence: [TopicReadingEvidence]
    public init(existingID:String,sourceIDs:[String],title:String,summary:String,reason:String,evidence:[TopicReadingEvidence]) {
        self.existingID=existingID;self.sourceIDs=sourceIDs;self.title=title;self.summary=summary;self.reason=reason;self.evidence=evidence
    }
}
public struct RecordingExpressionInput: Codable, Sendable {
    public let context: LocalTranscriptContext
    public let policies: [String:Int]
    public let newSourceIDs: [String]
    public let existing: [RecordingExpression]
    public let dates: [String:AutomaticRecordingInput]
    public let names: [String:String]
    public var recordingContexts: [RecordingContextSnapshot]? = nil
    public var correctedSourceGroups: [[String]]? = nil
}
public protocol RecordingExpressionPort: Sendable {
    func group(_ input:RecordingExpressionInput) async throws -> ([RecordingExpressionProposal],[String])
}
public struct ContinuousRecordingContext: Codable, Sendable {
    public let expressionID:String
    public let digest:String
    public let context:LocalTranscriptContext
    public let policies:[String:Int]
}

extension VoiceOSStore {
    func continuousRecordingContext(sourceID:String) throws -> ContinuousRecordingContext? {
        let catalog = try sourceCatalog()
        return try continuousRecordingContext(sourceID: sourceID, catalog: catalog,
                                              expressions: RecordingExpression.current(in: catalog))
    }
    /// Preloaded catalog and expressions keep per-receipt validation off the
    /// full-library read path.
    func continuousRecordingContext(sourceID:String, catalog:[String:SourceRecord], expressions:[RecordingExpression]) throws -> ContinuousRecordingContext? {
        guard let source = catalog[sourceID] else { return nil }
        let expression=expressions.first(where: { $0.sourceIDs.contains(sourceID) })
        if let expression,expression.state != "completed" { throw VoiceOSError("连续表达仍在整体理解，后续跟进稍后继续") }
        let members=expression?.sourceIDs ?? [sourceID]
        let expanded=try recordingContextSourceIDs(sourceIDs:members,catalog:catalog)
        guard members.count > 1 || expanded.count > members.count else { return nil }
        let context=try prepareLocalTranscriptContext(sourceIDs:expanded,scalarBudget:max(1,expanded.compactMap { catalog[$0] }.reduce(0) { $0 + ($1.transcript?.unicodeScalars.count ?? 0) }))
        let policies=Dictionary(uniqueKeysWithValues:expanded.compactMap { catalog[$0] }.map { ($0.id,$0.policyVersion) })
        return .init(expressionID:expression?.id ?? source.presentation?.recordingContext?.sessionID ?? sourceID,digest:context.contentDigest,context:context,policies:policies)
    }

    func validateContinuousRecordingContext(_ input:ContinuousRecordingContext?,sourceID:String,catalog:[String:SourceRecord],expressions:[RecordingExpression]) throws {
        guard let input else {
            if try continuousRecordingContext(sourceID:sourceID,catalog:catalog,expressions:expressions) != nil { throw VoiceOSError("单段跟进的依据已扩展为连续表达，需要结合全部分段") }
            return
        }
        guard let current=try continuousRecordingContext(sourceID:sourceID,catalog:catalog,expressions:expressions),try Self.relevanceJSON(current) == Self.relevanceJSON(input) else { throw VoiceOSError("连续表达的分段、原话或授权已变化") }
        try validateLocalTranscriptContext(input.context)
    }
    public func registerAutomaticRecording(sourceID:String,inbox:String,recordedAt:String?,discoveredAt:String? = nil) throws {
        guard let source=try sourceRecords(ids: [sourceID]).first,source.origin == "user",source.speaker == "user",!source.localOnly else { throw VoiceOSError("自动录音的归属或文字授权不可用") }
        var presentation=source.presentation ?? RecordingPresentation()
        guard presentation.automaticInput == nil else { return }
        presentation.automaticInput = .init(inbox:inbox,recordedAt:recordedAt,discoveredAt:discoveredAt ?? Self.now())
        try saveExpressionPresentation(presentation,sourceID:sourceID)
    }
    /// Old intake receipts prove import, not that continuity has been considered.
    /// Enrol only recordings already imported automatically and already allowed
    /// for text processing; never scan or grant access to untouched old files.
    public func enrollPreviouslyImportedAutomaticRecordings() throws {
        let imported=Set(try db.query("SELECT id FROM sources WHERE command_id LIKE 'automatic-recording:%'").compactMap { $0["id"] })
        let requested = Set(try recordingProcessingRequests().map(\.sourceID))
        let handled = Set(try db.query("""
            SELECT DISTINCT i.source_id FROM context_inputs i JOIN contexts c ON c.id=i.context_id
            JOIN model_attempts m ON m.context_id=c.id JOIN transcripts t ON t.source_id=i.source_id
            WHERE c.state='current' AND i.transcript_version_id=t.current_version_id
              AND (m.execution_kind IN ('model_request','segmented_derivation') OR m.provider='organized_import')
            """).compactMap { $0["source_id"] })
        for source in try sources() where ["audio","video"].contains(source.kind) && source.presentation?.automaticInput == nil && source.presentation?.expression == nil && source.origin == "user" && source.speaker == "user" && !source.localOnly && !source.isTrashed && !source.isArchived && source.state == "saved" && source.jobState == "completed" && !source.needsTranscriptionReview && !(source.transcript ?? "").isEmpty {
            let missing = source.transcriptionReview?.isCompleteFullTextReview == true && !handled.contains(source.id) && !requested.contains(source.id)
            guard imported.contains(source.id) || missing else { continue }
            try registerAutomaticRecording(sourceID:source.id,inbox:"previous-automatic-intake",recordedAt:source.expressedDate?.ISO8601Format(),discoveredAt:source.createdAt)
        }
    }
    public func completeUnchangedSingleRecording(_ expression:RecordingExpression) throws -> Bool {
        guard expression.sourceIDs.count == 1,let id=expression.sourceIDs.first else { return false }
        let catalog = try sourceCatalog()
        guard try recordingContext(sourceID:id,catalog:catalog) == nil,
              RecordingExpression.current(in: catalog).contains(where: { $0.id == expression.id && $0.digest == expression.digest }),
              try modelAttempts(sourceID:id).contains(where: { $0.provider == "organized_import" && $0.state == "completed" && $0.contextState == "current" }),
              let source=catalog[id],
              source.presentation?.automaticInput?.inbox == "previous-automatic-intake" else { return false }
        // No context was added: preserve the existing complete understanding and
        // its task states instead of extracting the same recording a second time.
        var completed=expression;completed.state="completed"
        var presentation=source.presentation!;presentation.expression=completed
        try saveExpressionPresentation(presentation,sourceID:id)
        try evaluateSourceExtractionFlags(sourceIDs: [id])
        return true
    }
    func saveExpressionPresentation(_ presentation:RecordingPresentation,sourceID:String) throws {
        try db.execute("UPDATE sources SET presentation_json=? WHERE id=?",[try Self.relevanceJSON(presentation),sourceID])
    }
    public func recordingExpressions() throws -> [RecordingExpression] {
        try RecordingExpression.current(in: sourceCatalog())
    }
    public func prepareRecordingExpressions() throws -> RecordingExpressionInput? {
        // The inbox records provenance, not a semantic boundary: phone sync and
        // a watched folder can deliver parts of the same expression.
        let records = try sources()
        let sourceCatalog = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let catalog=records.filter { $0.origin == "user" && $0.speaker == "user" && $0.presentation?.automaticInput != nil && !$0.localOnly && $0.state == "saved" && $0.jobState == "completed" && !$0.needsTranscriptionReview && !($0.transcript ?? "").isEmpty }
        let allowed=Set(catalog.map(\.id))
        let existing=RecordingExpression.current(in: sourceCatalog).filter { Set($0.sourceIDs).isSubset(of:allowed) }
        let assigned=Set(existing.flatMap(\.sourceIDs))
        let pending=catalog.filter { !assigned.contains($0.id) }.map(\.id)
        guard !pending.isEmpty else { return nil }
        let ordered=catalog.sorted {
            let a=$0.presentation!.automaticInput!,b=$1.presentation!.automaticInput!
            return (a.recordedAt ?? a.discoveredAt,$0.name,$0.id) < (b.recordedAt ?? b.discoveredAt,$1.name,$1.id)
        }
        let context=try prepareLocalTranscriptContext(sourceIDs:ordered.map(\.id),scalarBudget:max(1,ordered.reduce(0) { $0 + ($1.transcript?.unicodeScalars.count ?? 0) }))
        let correctedGroups = catalog.compactMap { $0.presentation?.correctedSourceIDs }.reduce(into: [[String]]()) { groups, ids in
            if !groups.contains(where: { Set($0) == Set(ids) }) { groups.append(ids) }
        }
        guard correctedGroups.allSatisfy({ Set($0).isSubset(of: allowed) }) else { throw VoiceOSError("同一次更正的完整录音尚未全部核对完成，暂不处理其中片段") }
        return .init(context:context,policies:Dictionary(catalog.map { ($0.id,$0.policyVersion) }, uniquingKeysWith:{ first,_ in first }),newSourceIDs:pending,existing:existing,dates:Dictionary(catalog.map { ($0.id,$0.presentation!.automaticInput!) }, uniquingKeysWith:{ first,_ in first }),names:Dictionary(catalog.map { ($0.id,$0.name) }, uniquingKeysWith:{ first,_ in first }),recordingContexts:try ordered.compactMap { try prepareRecordingContext(sourceID:$0.id,catalog:sourceCatalog) },correctedSourceGroups:correctedGroups)
    }
    public static func validateRecordingExpressions(_ proposals:[RecordingExpressionProposal],input:RecordingExpressionInput) throws {
        let sources=Dictionary(uniqueKeysWithValues:input.context.sources.map { ($0.sourceID,$0) })
        let existing=Dictionary(uniqueKeysWithValues:input.existing.map { ($0.id,$0) })
        let incoming=Set(input.newSourceIDs)
        var seen=Set<String>(),usedGroups=Set<String>()
        for proposal in proposals {
            let members=Set(proposal.sourceIDs)
            guard !members.isEmpty,members.count == proposal.sourceIDs.count,!members.isDisjoint(with:incoming),
                  seen.isDisjoint(with:members),members.isSubset(of:Set(sources.keys)),!proposal.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  !proposal.summary.isEmpty,!proposal.reason.isEmpty,!proposal.evidence.isEmpty else { throw VoiceOSError("连续表达分组缺失、重复或没有依据，原始录音保留") }
            var expected=incoming.intersection(members)
            if !proposal.existingID.isEmpty {
                guard let old=existing[proposal.existingID],usedGroups.insert(old.id).inserted else { throw VoiceOSError("连续表达引用了无效的旧分组") }
                expected.formUnion(old.sourceIDs)
            }
            guard members == expected else { throw VoiceOSError("连续表达不能遗漏原有分段或混入其他表达") }
            var cited=Set<String>()
            for evidence in proposal.evidence {
                guard members.contains(evidence.sourceID),!evidence.quote.isEmpty,sources[evidence.sourceID]?.text.contains(evidence.quote) == true else { throw VoiceOSError("连续表达的合并依据无法定位到原话") }
                cited.insert(evidence.sourceID)
            }
            guard cited == members else { throw VoiceOSError("连续表达需要逐段保留合并依据") }
            // Trust actual recording timestamps, never a model-invented chronology.
            let known=proposal.sourceIDs.compactMap { input.dates[$0]?.recordedAt }
            guard known == known.sorted() else { throw VoiceOSError("连续表达的录音顺序与已知时间不符") }
            seen.formUnion(members)
        }
        guard seen.intersection(incoming) == incoming else { throw VoiceOSError("连续表达遗漏新录音，未保存部分结果") }
        for group in input.correctedSourceGroups ?? [] {
            let members = Set(group)
            guard !members.isEmpty, proposals.filter({ !members.isDisjoint(with: $0.sourceIDs) }).count == 1,
                  proposals.contains(where: { members.isSubset(of: Set($0.sourceIDs)) }) else {
                throw VoiceOSError("原文更正不能拆散原有完整表达，原始录音与任务历史保留")
            }
        }
    }
    public func connectRecordingExpressions(using port:any RecordingExpressionPort) async throws -> [RecordingExpression] {
        guard let input=try prepareRecordingExpressions() else { return try recordingExpressions().filter { $0.state != "completed" } }
        let (proposals,receipts)=try await port.group(input)
        try validateLocalTranscriptContext(input.context)
        let catalog = try sourceCatalog()
        for snapshot in input.recordingContexts ?? [] {
            try validateLocalTranscriptContext(snapshot.context)
            guard let current=try prepareRecordingContext(sourceID:snapshot.pairing.personalSourceID,catalog:catalog),try Self.relevanceJSON(current) == Self.relevanceJSON(snapshot) else { throw VoiceOSError("节目上下文在连续表达判断期间已变化") }
        }
        for (id,version) in input.policies { guard try sourcePolicy(sourceID:id).version == version else { throw VoiceOSError("分组合并期间文字授权已变化") } }
        guard receipts.count >= 2,Set(receipts).count == receipts.count else { throw VoiceOSError("连续表达缺少独立核对回执") }
        try Self.validateRecordingExpressions(proposals,input:input)
        let allActions=try actions(includeHistory:true),claims=Dictionary(uniqueKeysWithValues:try candidateClaims(includeFrozen:true).map { ($0.id,$0) })
        let correctionActions=catalog.mapValues { Set($0.presentation?.correctedActionIDs ?? []) }
        return try db.transaction {
            var result:[RecordingExpression]=[]
            for proposal in proposals {
                let members=Set(proposal.sourceIDs)
                let retainedCorrectionIDs=members.reduce(into:Set<String>()) { $0.formUnion(correctionActions[$1] ?? []) }
                let previous=allActions.filter { action in
                    guard action.validity == "current" || retainedCorrectionIDs.contains(action.id),let claim=claims[action.claimID] else { return false }
                    return !members.isDisjoint(with:claim.references.map(\.sourceID))
                }.map(\.id)
                let expression=RecordingExpression(id:proposal.existingID.isEmpty ? UUID().uuidString : proposal.existingID,sourceIDs:proposal.sourceIDs,title:proposal.title,summary:proposal.summary,reason:proposal.reason,responseIDs:receipts,versions:Dictionary(uniqueKeysWithValues:input.context.sources.filter { members.contains($0.sourceID) }.map { ($0.sourceID,$0.transcriptVersionID) }),policies:input.policies.filter { members.contains($0.key) },state:"pending",previousActionIDs:previous,externalVersions:Dictionary((input.recordingContexts ?? []).filter { members.contains($0.pairing.personalSourceID) }.map { ($0.pairing.externalSourceID,$0.pairing.externalVersionID) },uniquingKeysWith:{ first,_ in first }),externalPolicies:Dictionary((input.recordingContexts ?? []).filter { members.contains($0.pairing.personalSourceID) }.map { ($0.pairing.externalSourceID,$0.pairing.externalPolicyVersion) },uniquingKeysWith:{ first,_ in first }))
                for id in proposal.sourceIDs {
                    guard let source=catalog[id] else { throw VoiceOSError("录音缺失") }
                    var presentation=source.presentation ?? RecordingPresentation();presentation.expression=expression
                    try saveExpressionPresentation(presentation,sourceID:id)
                }
                result.append(expression)
            }
            return result
        }
    }
    public func finishRecordingExpression(_ expression:RecordingExpression,using port:any RecordingExpressionActionPort) async throws {
        guard let current=try recordingExpressions().first(where: { $0.id == expression.id }),current.sourceIDs == expression.sourceIDs,current.versions == expression.versions else { throw VoiceOSError("连续表达在整理期间已变化") }
        var completed=current;completed.state="completed"
        let input=try prepareExpressionActionReview(current)
        var decisions:[RecordingExpressionActionDecision]=[]
        if !input.oldActions.isEmpty {
            let reviewed=try await port.reconcile(input)
            try validateLocalTranscriptContext(input.context)
            guard try Self.relevanceJSON(prepareExpressionActionReview(current)) == Self.relevanceJSON(input) else { throw VoiceOSError("接续核对期间行动或原话已变化，等待重新核对") }
            try Self.validateExpressionActionReview(reviewed.0,input:input)
            guard reviewed.1.count >= 2,Set(reviewed.1).count == reviewed.1.count,reviewed.1.allSatisfy({ !$0.isEmpty }) else { throw VoiceOSError("补录任务接续缺少独立核对") }
            decisions=reviewed.0;completed.actionReviewResponseIDs=reviewed.1
        }
        completed.reminderUpdates=decisions.filter { $0.relation == "same" || $0.relation == "withdraw" }.map(\.oldID)
        completed.taskReviewPending=decisions.contains { $0.relation == "uncertain" }
        completed.actionReviewDecisions=decisions
        let latest=try latestCandidateClaimsBySource()
        // The organizing attempt also owns separately attributed programme claims.
        // Keep its current cited companions when retiring older personal results.
        let keep=Set(input.context.sources.flatMap { latest[$0.sourceID] ?? [] }.map(\.id))
        var replaced=Set<String>()
        for id in expression.sourceIDs {
            for row in try db.query("SELECT c.id FROM claims c JOIN model_attempts m ON m.id=c.attempt_id JOIN context_inputs i ON i.context_id=m.context_id WHERE i.source_id=? AND m.provider='organized_import' AND c.validity='current'",[id]) where !keep.contains(row["id"]!) { replaced.insert(row["id"]!) }
        }
        let members = Dictionary(try sourceRecords(ids: completed.sourceIDs).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        try db.transaction {
            _ = try reconcileExpressionActions(decisions,input:input,responseIDs:completed.actionReviewResponseIDs ?? [])
            for id in replaced {
                try db.execute("UPDATE claims SET validity='frozen' WHERE id=?",[id])
                try db.execute("UPDATE actions SET validity='frozen' WHERE claim_id=?",[id])
            }
            for id in completed.sourceIDs {
                guard var presentation=members[id]?.presentation else { throw VoiceOSError("录音缺失") }
                presentation.expression=completed
                presentation.correctedActionIDs=nil;presentation.correctedSourceIDs=nil;presentation.recordingUnderstandingIsCorrection=nil
                try saveExpressionPresentation(presentation,sourceID:id)
            }
            try Self.validateStoredExpressionActionReviews(db)
        }
        // The group just settled; each member's zero-extraction state is now final.
        try evaluateSourceExtractionFlags(sourceIDs: Set(completed.sourceIDs))
    }
}
