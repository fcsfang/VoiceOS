import XCTest
@testable import VoiceOSCore

final class PausedActionBatchPlanChecks: XCTestCase {
    private func source(_ id: String, createdAt: String, transcript: String? = "原话内容", state: String = "saved",
                        localOnly: Bool = false, origin: String = "user", speaker: String = "user",
                        kind: String = "user_text", backend: String? = nil,
                        presentation: RecordingPresentation? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: state, kind: kind, createdAt: createdAt,
                     bytes: 1, duration: nil, jobState: "completed", transcript: transcript, error: nil,
                     relativePath: "assets/" + id, transcriptVersionID: "t-" + id, transcriptionBackend: backend,
                     spans: [], localOnly: localOnly, policyVersion: 1, origin: origin, speaker: speaker,
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                     timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private func claim(_ id: String, sourceIDs: [String], validity: String = "current",
                       reviewVersion: Int = 1) -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: "理解 " + id, ownership: "user_tentative",
                       evidenceState: "unverified", validity: validity,
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: reviewVersion, reviewState: "pending")
    }

    private func action(_ id: String, claimID: String, validity: String = "frozen", state: String = "open",
                        reviewVersion: Int = 1, followupState: String = "pending") -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: reviewVersion, title: "待办 " + id,
                     kind: "task", intentActor: "user", note: "", state: state, validity: validity,
                     version: 1, autoSend: true,
                     intent: ActionIntentMetadata(intentType: "task", followupState: followupState, uncertain: false))
    }

    private func expressionPresentation(actionID: String) -> RecordingPresentation {
        var presentation = RecordingPresentation()
        var expression = RecordingExpression(id: "expression-" + actionID, sourceIDs: ["cause-a"],
                                             title: "完整表达", summary: "摘要", reason: "依据",
                                             responseIDs: ["response"], versions: ["cause-a": "t-cause-a"],
                                             policies: ["cause-a": 1], state: "completed",
                                             previousActionIDs: [actionID])
        expression.taskReviewPending = true
        presentation.expression = expression
        return presentation
    }

    private func snapshot(_ sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord],
                          currentClaimsBySource: [String: [CandidateClaim]],
                          processingIntents: [ExpressionProcessingIntentRecord] = [],
                          segmentedBatches: [SegmentedProcessingBatch] = [],
                          recordingRequests: [RecordingProcessingRequest] = []) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot()
        snapshot.sources = sources
        snapshot.claims = claims
        snapshot.actions = actions
        snapshot.currentClaimsBySource = currentClaimsBySource
        snapshot.processingIntents = processingIntents
        snapshot.segmentedBatches = segmentedBatches
        snapshot.recordingRequests = recordingRequests
        return snapshot
    }

    private func fixtureConfiguration() -> ModelConfiguration {
        .init(provider: "fixture", model: "flow", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    }

    private func processingIntent(_ sourceID: String, state: ExpressionProcessingIntentState = .queued) -> ExpressionProcessingIntentRecord {
        let configuration = fixtureConfiguration()
        let context = LocalTranscriptContext(
            sources: [ContextTranscript(sourceID: sourceID, sourceVersionID: "v-" + sourceID,
                                        transcriptVersionID: "t-" + sourceID, origin: "user", speaker: "user",
                                        localOnly: false, text: "原话", spans: [TranscriptSpan(textStart: 0, textEnd: 2)])],
            scalarBudget: 4000, contentDigest: "digest-" + sourceID)
        let intentSnapshot = ExpressionProcessingIntentSnapshot(id: UUID().uuidString, context: context,
                                                                policyVersion: 1,
                                                                cognition: ProcessingModelIdentity(configuration),
                                                                association: ProcessingModelIdentity(configuration),
                                                                contentDigest: "digest-" + sourceID)
        return ExpressionProcessingIntentRecord(id: UUID().uuidString, commandID: "command-" + sourceID,
                                                sourceID: sourceID, snapshot: intentSnapshot, state: state,
                                                phase: .queued, cognitionAttemptID: nil, associationAttemptID: nil,
                                                error: nil, cancelReason: nil,
                                                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }

    private func segmentedBatch(_ sourceID: String) -> SegmentedProcessingBatch {
        let configuration = fixtureConfiguration()
        let context = ContextTranscript(sourceID: sourceID, sourceVersionID: "v-" + sourceID,
                                        transcriptVersionID: "t-" + sourceID, origin: "user", speaker: "user",
                                        localOnly: false, text: "原话", spans: [TranscriptSpan(textStart: 0, textEnd: 2)])
        let plan = TranscriptSegmentationPlan(
            algorithm: "transcript-segmentation-v1", source: context, policyVersion: 1, scalarBudget: 2,
            segments: [
                TranscriptSegment(id: "segment-1", ordinal: 1, textStart: 0, textEnd: 1, text: "原",
                                  references: [.init(spanID: "span", textStart: 0, textEnd: 1, containingSpanStartMS: nil, containingSpanEndMS: nil)]),
                TranscriptSegment(id: "segment-2", ordinal: 2, textStart: 1, textEnd: 2, text: "话",
                                  references: [.init(spanID: "span", textStart: 1, textEnd: 2, containingSpanStartMS: nil, containingSpanEndMS: nil)])
            ],
            contentDigest: "segments-" + sourceID)
        let scope = SegmentedExpressionProcessingScope(id: UUID().uuidString, plan: plan,
                                                       extraction: ProcessingModelIdentity(configuration),
                                                       aggregation: ProcessingModelIdentity(configuration),
                                                       evidenceScalarBudget: 4000, contentDigest: "scope-" + sourceID)
        return SegmentedProcessingBatch(id: UUID().uuidString, commandID: "command-" + sourceID, scope: scope,
                                        state: .queued, error: nil,
                                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }

    func testPausedActionBatchPlanDeduplicatesAndOrdersSources() {
        let a = source("source-a", createdAt: "2026-01-03T00:00:00Z", transcript: "甲的原话")
        let b = source("source-b", createdAt: "2026-01-01T00:00:00Z", transcript: "乙的原话")
        let c = source("source-c", createdAt: "2026-01-02T00:00:00Z", transcript: "丙的原话")
        let claimA1 = claim("claim-a1", sourceIDs: ["source-a"])
        let claimA2 = claim("claim-a2", sourceIDs: ["source-a"])
        let claimAB = claim("claim-ab", sourceIDs: ["source-a", "source-b"])
        let claims = [claimA1, claimA2, claimAB]
        let actions = [action("action-a1", claimID: "claim-a1"),
                       action("action-a2", claimID: "claim-a2"),
                       action("action-ab", claimID: "claim-ab")]
        let plan = PausedActionBatch.plan(snapshot: snapshot([a, c, b], claims: claims, actions: actions,
                                                             currentClaimsBySource: ["source-a": claims,
                                                                                     "source-b": [claimAB],
                                                                                     "source-c": []]))
        XCTAssertEqual(plan.targets.map(\.sourceID), ["source-b", "source-a"])
        XCTAssertEqual(plan.targets[0].actionIDs, ["action-ab"])
        XCTAssertEqual(plan.targets[1].actionIDs, ["action-a1", "action-a2", "action-ab"])
        XCTAssertEqual(plan.targetActionCount, 3)
        XCTAssertEqual(plan.affectedMaterialCount, 2)
        XCTAssertEqual(plan.targets[1].causes, [.extractionPaused])
        XCTAssertTrue(plan.reviewOnlyActionIDs.isEmpty)
        XCTAssertTrue(plan.withdrawnActionIDs.isEmpty)
        XCTAssertTrue(plan.unattachedActionIDs.isEmpty)
        XCTAssertTrue(plan.skips.isEmpty)
    }

    func testPausedActionBatchPlanClassifiesCausesSkipsAndRoutes() {
        let cause = source("cause-a", createdAt: "2026-02-01T00:00:00Z", presentation: expressionPresentation(actionID: "action-review"))
        let withdrawn = source("withdrawn", createdAt: "2026-02-02T00:00:00Z")
        let quarantined = source("quarantined", createdAt: "2026-02-03T00:00:00Z", state: "quarantined")
        let missing = source("missing", createdAt: "2026-02-04T00:00:00Z", transcript: nil)
        let local = source("local", createdAt: "2026-02-05T00:00:00Z", localOnly: true)
        let additionalBusy = source("additional-busy", createdAt: "2026-02-06T00:00:00Z")
        let intentBusy = source("intent-busy", createdAt: "2026-02-07T00:00:00Z")
        let batchBusy = source("batch-busy", createdAt: "2026-02-08T00:00:00Z")
        let requestBusy = source("request-busy", createdAt: "2026-02-09T00:00:00Z")
        let recording = source("recording", createdAt: "2026-02-10T00:00:00Z", transcript: "短录音原话", backend: "Qwen3-ASR-1.7B")
        let long = source("long", createdAt: "2026-02-11T00:00:00Z", transcript: String(repeating: "字", count: 4001))
        let short = source("short", createdAt: "2026-02-12T00:00:00Z", transcript: "短文字")
        let external = source("external", createdAt: "2026-02-13T00:00:00Z", transcript: "外部原话", origin: "external", speaker: "unknown")
        let higher = source("higher", createdAt: "2026-02-14T00:00:00Z")
        let replaced = source("replaced", createdAt: "2026-02-15T00:00:00Z")
        let unattached = source("unattached", createdAt: "2026-02-16T00:00:00Z")
        let cReview = claim("claim-review", sourceIDs: ["cause-a"])
        let cWithdrawn = claim("claim-withdrawn", sourceIDs: ["withdrawn"])
        let cQuarantined = claim("claim-quarantined", sourceIDs: ["quarantined"])
        let cMissing = claim("claim-missing", sourceIDs: ["missing"])
        let cLocal = claim("claim-local", sourceIDs: ["local"])
        let cAdditional = claim("claim-additional", sourceIDs: ["additional-busy"])
        let cIntent = claim("claim-intent", sourceIDs: ["intent-busy"])
        let cBatch = claim("claim-batch", sourceIDs: ["batch-busy"])
        let cRequest = claim("claim-request", sourceIDs: ["request-busy"])
        let cRecording = claim("claim-recording", sourceIDs: ["recording"])
        let cLong = claim("claim-long", sourceIDs: ["long"])
        let cShort = claim("claim-short", sourceIDs: ["short"])
        let cExternal = claim("claim-external", sourceIDs: ["external"])
        let cHigher = claim("claim-higher", sourceIDs: ["higher"])
        let cReplaced = claim("claim-replaced", sourceIDs: ["replaced"])
        let cUnattached = claim("claim-unattached", sourceIDs: [])
        let claims = [cReview, cWithdrawn, cQuarantined, cMissing, cLocal, cAdditional, cIntent, cBatch,
                      cRequest, cRecording, cLong, cShort, cExternal, cHigher, cReplaced, cUnattached]
        let actions = [action("action-review", claimID: "claim-review", validity: "current"),
                       action("action-withdrawn", claimID: "claim-withdrawn", followupState: "withdrawn"),
                       action("action-quarantined", claimID: "claim-quarantined"),
                       action("action-missing", claimID: "claim-missing"),
                       action("action-local", claimID: "claim-local"),
                       action("action-additional", claimID: "claim-additional"),
                       action("action-intent", claimID: "claim-intent"),
                       action("action-batch", claimID: "claim-batch"),
                       action("action-request", claimID: "claim-request"),
                       action("action-recording", claimID: "claim-recording"),
                       action("action-long", claimID: "claim-long"),
                       action("action-short", claimID: "claim-short"),
                       action("action-external", claimID: "claim-external"),
                       action("action-older", claimID: "claim-higher", reviewVersion: 1),
                       action("action-newer", claimID: "claim-higher", validity: "current", reviewVersion: 2),
                       action("action-replaced", claimID: "claim-replaced"),
                       action("action-unattached", claimID: "claim-unattached")]
        let replacement = claim("claim-new", sourceIDs: ["replaced"])
        var current: [String: [CandidateClaim]] = [:]
        for claim in claims {
            for reference in claim.references {
                current[reference.sourceID, default: []].append(claim)
            }
        }
        current["replaced"] = [replacement]
        let plan = PausedActionBatch.plan(
            snapshot: snapshot([requestBusy, local, cause, quarantined, missing, additionalBusy, intentBusy,
                                batchBusy, recording, long, short, external, higher, replaced, unattached, withdrawn],
                               claims: claims + [replacement], actions: actions,
                               currentClaimsBySource: current,
                               processingIntents: [processingIntent("intent-busy")],
                               segmentedBatches: [segmentedBatch("batch-busy")],
                               recordingRequests: [RecordingProcessingRequest(id: "request-1", sourceID: "request-busy",
                                                                              state: "waiting", processingIntentID: nil,
                                                                              segmentedBatchID: nil,
                                                                              segmentedAssociationState: nil, error: nil)]),
            additionallyBusySources: ["additional-busy"])
        XCTAssertEqual(plan.reviewOnlyActionIDs, ["action-review"])
        XCTAssertEqual(plan.withdrawnActionIDs, ["action-withdrawn"])
        XCTAssertEqual(plan.unattachedActionIDs, ["action-unattached"])
        XCTAssertNil(plan.targets.first { $0.sourceID == "higher" })
        XCTAssertNil(plan.targets.first { $0.sourceID == "replaced" })
        XCTAssertTrue(plan.skips.allSatisfy { $0.sourceID != "higher" && $0.sourceID != "replaced" })
        XCTAssertEqual(plan.targets.first { $0.sourceID == "recording" }?.route, .wholeRecording)
        XCTAssertEqual(plan.targets.first { $0.sourceID == "long" }?.route, .segmented)
        XCTAssertEqual(plan.targets.first { $0.sourceID == "short" }?.route, .textUnderstanding)
        XCTAssertEqual(plan.targets.first { $0.sourceID == "external" }?.route, .textUnderstanding)
        XCTAssertEqual(plan.affectedMaterialCount, 4)
        XCTAssertEqual(plan.targetActionCount, 4)
        XCTAssertEqual(plan.skips.map(\.sourceID),
                       ["quarantined", "missing", "local", "additional-busy", "intent-busy", "batch-busy", "request-busy"])
        XCTAssertEqual(plan.skips.first { $0.sourceID == "quarantined" }?.reason, .quarantined)
        XCTAssertEqual(plan.skips.first { $0.sourceID == "missing" }?.reason, .missingTranscript)
        XCTAssertEqual(plan.skips.first { $0.sourceID == "local" }?.reason, .localOnly)
        XCTAssertEqual(plan.skips.first { $0.sourceID == "additional-busy" }?.reason, .busy)
        XCTAssertEqual(plan.skips.first { $0.sourceID == "intent-busy" }?.reason, .busy)
        XCTAssertEqual(plan.skips.first { $0.sourceID == "batch-busy" }?.reason, .busy)
        XCTAssertEqual(plan.skips.first { $0.sourceID == "request-busy" }?.reason, .busy)
    }
}
