import Foundation
import Darwin
import VoiceOSCore
import VoiceOSPlatform
import AVFoundation

@main
struct Check {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else { throw VoiceOSError("usage: voiceos-check <import|read|transcribe> <isolated-root> [file] [command-id]") }
            if args[0] == "personal-short-cloud-probe" { try await runPersonalShortCloudProbe(args); return }
            if args[0] == "personal-segment-cloud-probe" { try await runPersonalSegmentCloudProbe(args); return }
            if args[0] == "config-check" { try runConfigCheck(URL(fileURLWithPath: args[1])); return }
            if args[0] == "outcome-cloud-fixture" { try await runOutcomeCloudFixture(args); return }
            if args[0] == "english-ui-seed" { try await runEnglishUISeed(args); return }
            if args[0] == "english-cloud-fixture" { try await runEnglishCloudFixture(args); return }
            if args[0] == "discussion-cloud-fixture" { try await runDiscussionCloudFixture(args); return }
            if args[0] == "retrieval-fixture" { try await runRetrievalFixture(args); return }
            if args[0] == "bge-eval" { try await runBGEEvaluation(args); return }
            if args[0] == "relevance-fixture" { try await runRelevanceFixture(args); return }
            if args[0] == "relevance-cloud-fixture" { try await runRelevanceCloudFixture(args); return }
            if args[0] == "expression-eval-fixture" { try await runExpressionEvaluation(args); return }
            if args[0] == "expression-cloud-fixture" { try await runExpressionCloudFixture(args); return }
            if args[0] == "cloud-fixture" { try await runCloudFixture(args); return }
            if args[0] == "restore" {
                guard args.count == 3 else { throw VoiceOSError("restore requires package path") }
                try await VoiceOSStore.restorePackage(from: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[1]), inspector: NativeMediaInspector())
                print("{\"restored\":true}")
                return
            }
            let crash = ProcessInfo.processInfo.environment["VOICEOS_TEST_CRASH_AT"]
            let store = try VoiceOSStore(root: URL(fileURLWithPath: args[1]), inspector: NativeMediaInspector(), checkpoint: { point in
                if point.rawValue == crash {
                    kill(getpid(), SIGKILL)
                    // Signal delivery can lag on another thread; never cross the commit boundary.
                    while true { pause() }
                }
            })
            try await store.recover()
            if args[0] == "question-active-answer-fixture" { try await runQuestionActiveAnswerFixture(store); return }
            if args[0] == "question-reopen-fixture" { try await runQuestionReopenFixture(store); return }
            if args[0] == "question-association-fixture" { try await runQuestionAssociationFixture(store); return }
            if args[0] == "question-close-fixture" { try await runQuestionCloseFixture(store); return }
            if args[0] == "typed-cognition-fixture" { try await runTypedCognitionFixture(store); return }
            if args[0] == "discussion-question-fixture" { try await runDiscussionQuestionFixture(store); return }
            if args[0] == "source-continuation-fixture" { try await runSourceContinuationFixture(store); return }
            if ["record-request-fixture", "record-request-resume-fixture"].contains(args[0]) { try await runRecordingRequestFixture(store, seed:args[0] == "record-request-fixture"); return }
            if args[0] == "segment-cognition-personal-fixture" { try await runPersonalSegmentCognition(store,args:args); return }
            if ["segment-extraction-fixture", "segment-extraction-personal-fixture", "segment-extraction-read"].contains(args[0]) {
                try await runSegmentExtractionFixture(store,args:args); return
            }
            if args[0] == "segmented-batch-enqueue-local" {
                guard args.count >= 3 else { throw VoiceOSError("local batch enqueue requires explicit source ID") }
                let config = ModelConfiguration(provider:"local_batch_inspection",model:"no-dispatch",promptVersion:"v1",schemaVersion:"v1",destination:.local)
                let scope = try await store.prepareSegmentedExpressionProcessingScope(sourceID:args[2],extraction:config,aggregation:config)
                _ = try await store.enqueueSegmentedProcessingBatch(scope,commandID:args.count > 3 ? args[3] : UUID().uuidString,extraction:config,aggregation:config)
            }
            if ["segmented-batch-fixture", "segmented-batch-cancel-fixture"].contains(args[0]) {
                let config = ModelConfiguration(provider:"local_batch_fixture",model:"no-dispatch",promptVersion:"v1",schemaVersion:"v1",destination:.local)
                let source = try await store.recordUserExpression(String(repeating:"合成原话。",count:20),commandID:"segmented-fixture-source")
                let scope = try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:config,aggregation:config,segmentScalarBudget:20)
                let batch = try await store.enqueueSegmentedProcessingBatch(scope,commandID:"segmented-fixture-command",extraction:config,aggregation:config)
                if args[0] == "segmented-batch-cancel-fixture" { _ = try await store.cancelSegmentedProcessingBatch(id:batch.id) }
                else { _ = try await store.checkSegmentedProcessingBatch(id:batch.id,extraction:config,aggregation:config) }
            }
            if ["segmented-batch-read", "segmented-batch-fixture", "segmented-batch-cancel-fixture", "segmented-batch-enqueue-local"].contains(args[0]) {
                let batches = try await store.segmentedProcessingBatches()
                var segmentCount = 0
                for batch in batches { segmentCount += try await store.segmentExtractionAttempts(batchID:batch.id).count }
                let output:[String:Any] = ["segment_attempt_count":segmentCount,"integrity":try await store.integrityCheck(),"batches":batches.map { ["id":$0.id,"state":$0.state.rawValue,"segment_count":$0.scope.plan.segments.count] },"model_count":try await store.modelAttempts().count,"queue_count":try await store.processingIntents().count,"action_count":try await store.actions().count]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            }
            if args[0] == "segmented-scope-read" {
                guard let source = try await store.sources().first(where: { args.count > 2 ? $0.id == args[2] : $0.transcript != nil }) else { throw VoiceOSError("scope requires current personal transcript") }
                let config = ModelConfiguration(provider:"local_scope_inspection",model:"no-dispatch",promptVersion:"scope-v1",schemaVersion:"scope-v1",destination:.local)
                let scope = try await store.prepareSegmentedExpressionProcessingScope(sourceID:source.id,extraction:config,aggregation:config)
                try await store.validateSegmentedExpressionProcessingScope(scope,extraction:config,aggregation:config)
                let output:[String:Any] = ["preparation_only":true,"source_id":source.id,"scope_digest":scope.contentDigest,"policy_version":scope.plan.policyVersion,"local_only":scope.plan.source.localOnly,"segment_count":scope.plan.segments.count,"evidence_budget":scope.evidenceScalarBudget,"model_count":try await store.modelAttempts().count,"queue_count":try await store.processingIntents().count]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            }
            if args[0] == "transcript-segmentation-read" {
                let budget = args.count > 2 ? Int(args[2]) : 4000
                guard let budget, let source = try await store.sources().first(where: { args.count > 3 ? $0.id == args[3] : $0.transcript != nil }) else { throw VoiceOSError("segmentation requires transcript and valid budget") }
                let plan = try await store.prepareTranscriptSegmentation(sourceID:source.id,scalarBudget:budget)
                try await store.validateTranscriptSegmentation(plan)
                let output:[String:Any] = ["source_id":source.id,"transcript_version_id":plan.source.transcriptVersionID,"policy_version":plan.policyVersion,"origin":plan.source.origin,"speaker":plan.source.speaker,"local_only":plan.source.localOnly,"plan_digest":plan.contentDigest,"budget":budget,"text_scalars":plan.source.text.unicodeScalars.count,"segment_count":plan.segments.count,"lossless":plan.segments.map(\.text).joined() == plan.source.text,"segments":plan.segments.map { ["id":$0.id,"ordinal":$0.ordinal,"start":$0.textStart,"end":$0.textEnd,"reference_count":$0.references.count] as [String:Any] },"integrity":try await store.integrityCheck(),"model_calls":try await store.modelAttempts().count,"queue_count":try await store.processingIntents().count]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            }
            if args[0] == "record-request-read" {
                let requests = try await store.recordingProcessingRequests()
                let output:[String:Any] = ["integrity":try await store.integrityCheck(), "requests":requests.map { ["id":$0.id,"source_id":$0.sourceID,"state":$0.state,"queue_id":$0.processingIntentID ?? ""] },"queue_states":try await store.processingIntents().map { $0.state.rawValue },"queue_count":try await store.processingIntents().count,"model_count":try await store.modelAttempts().count,"association_count":try await store.expressionAssociationAttempts().count]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            }
            if ["expression-queue-fixture", "personal-audio-queue-fixture"].contains(args[0]) { try await runExpressionQueueFixture(store, existingAudio: args[0] == "personal-audio-queue-fixture"); return }
            if args[0] == "expression-queue-read" {
                let intents = try await store.processingIntents()
                let output:[String:Any] = ["integrity":try await store.integrityCheck(),
                    "cognition_attempt_count":try await store.modelAttempts().count,
                    "association_attempt_count":try await store.expressionAssociationAttempts().count,
                    "intents":intents.map { ["id":$0.id,"state":$0.state.rawValue,"phase":$0.phase.rawValue,"cognition_attempt_id":$0.cognitionAttemptID ?? "","association_attempt_id":$0.associationAttemptID ?? ""] as [String:Any] }]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            }
            if args[0] == "association-fixture" { try await runAssociationFixture(store); return }
            if args[0] == "association-driver-fixture" {
                guard args.count == 2 || args.count == 3 else { throw VoiceOSError("association-driver-fixture requires isolated root and optional reviewed semantic model") }
                try await runAssociationFixture(store, automatic: true, semanticRoot: args.count == 3 ? URL(fileURLWithPath: args[2]) : nil)
                return
            }
            if args[0] == "association-ignore-fixture" { try await runAssociationIgnoreFixture(store); return }
            if args[0] == "outcome-ui-seed" {
                guard try await store.sources().isEmpty else { throw VoiceOSError("synthetic UI seed requires an empty root") }
                let first=try await seedOutcomeConversation(store,index:0,secondText:"合成个人：我会整理开发验证素材。如果条件不满足，我暂不调整实验；我现在不打算阅读论文。")
                let restricted=try await seedOutcomeConversation(store,index:1,secondText:"合成个人：那就按第二个方案继续，但如果条件不满足就先不做。不要替我购买设备。",historyLocalOnly:true)
                let data=try JSONSerialization.data(withJSONObject:["synthetic_only":true,"eligible_conversation_id":first,"restricted_conversation_id":restricted,"cloud_calls":0],options:[.sortedKeys])
                print(String(decoding:data,as:UTF8.self));return
            }
            if args[0] == "outcome-reuse-fixture" {
                try await runOutcomeReuseFixture(store)
                print("{\"integrity\":\(try await store.integrityCheck())}");return
            }
            if ["conversation-entry-fixture","conversation-turn-fixture","conversation-end-fixture","discussion-fixture","discussion-candidate-fixture","discussion-anchor-fixture","outcome-fixture","outcome-feedback-fixture"].contains(args[0]) {
                let source = try await store.recordUserExpression("合成旧观点：需要检验条件，尚未形成结论。",commandID:"synthetic-dialogue-history")
                let id = try await store.beginConversation(sourceIDs:[source],commandID:"synthetic-dialogue-entry")
                if args[0] != "conversation-entry-fixture" {
                    let turnSource = try await store.recordUserExpression(["outcome-fixture","outcome-feedback-fixture"].contains(args[0]) ? "合成个人：我会整理开发验证素材。我现在不打算阅读论文。" : "合成追问：哪些反例能够限制这个猜想？",commandID:"synthetic-dialogue-user-source")
                    _ = try await store.appendConversationUserSource(conversationID:id,sourceID:turnSource,expectedVersion:1,commandID:"synthetic-dialogue-turn")
                }
                if args[0] == "conversation-end-fixture" { try await store.endConversation(id:id,expectedVersion:2,commandID:"synthetic-dialogue-end") }
                if ["discussion-fixture","discussion-candidate-fixture","discussion-anchor-fixture","outcome-fixture","outcome-feedback-fixture"].contains(args[0]), try await store.discussionAttempts(conversationID:id).isEmpty {
                    let input = try await store.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
                    _ = try await store.performConversationReply(input,using:LocalDiscussionFixture(cited:args[0] != "discussion-anchor-fixture"))
                }
                if ["outcome-fixture","outcome-feedback-fixture"].contains(args[0]) {
                    try await store.endConversation(id:id,expectedVersion:2,commandID:"synthetic-outcome-end")
                    if try await store.conversationOutcomes(conversationID:id).isEmpty {
                        let input=try await store.prepareConversationOutcome(id:id,expectedVersion:3,destination:.local,commandID:"synthetic-outcome-input")
                        _=try await store.performConversationOutcome(input,using:LocalOutcomeFixture())
                    }
                }
                if args[0] == "outcome-feedback-fixture" {
                    guard let action=try await store.actions(includeHistory:true).first(where: { $0.kind == "task" }) else { throw VoiceOSError("missing synthetic outcome task") }
                    _=try await store.setActionState(actionID:action.id,expectedVersion:1,state:.completed,commandID:"synthetic-outcome-completed")
                    _=try await store.recordActionFeedback(actionID:action.id,expectedVersion:2,kind:.outcome,text:"合成结果验证：素材已整理，只验证流程，并未证明技术猜想。",commandID:"synthetic-outcome-feedback")
                }
                if args[0] == "discussion-candidate-fixture" {
                    guard let reply=try await store.discussionAttempts(conversationID:id).first else { throw VoiceOSError("missing synthetic reply") }
                    _=try await store.retainDiscussionAICandidate(attemptID:reply.id,partIndex:1,commandID:"synthetic-ai-candidate")
                }
            } else if ["discussion-outcome-prepare","outcome-reuse-plan"].contains(args[0]) {
                guard args.count == 3 else { throw VoiceOSError("outcome preparation requires conversation ID") }
                let session=try await store.conversation(id:args[2])
                let input=try await store.prepareConversationOutcome(id:session.id,expectedVersion:session.version,destination:.local,commandID:"synthetic-outcome-input")
                try await store.validateConversationOutcome(input)
                if args[0] == "outcome-reuse-plan" {
                    let plan=try await store.conversationOutcomeReusePlan(for:input)
                    try await store.validateConversationOutcomeReusePlan(plan,snapshot:input)
                    let output:[String:Any]=["integrity":try await store.integrityCheck(),"full_source_count":input.context.sources.count,"full_personal_turn_count":input.input.userTurns.count,"full_reply_count":input.replies.count,"personal_target_turn_ids":plan.personalTargets.map(\.turnID),"prior_results":plan.priorResults.map { ["attempt_id":$0.attemptID,"kind":$0.kind,"state":$0.state,"claim_ids":$0.claimIDs] as [String:Any] }]
                    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self));return
                }
                let output:[String:Any]=["integrity":try await store.integrityCheck(),"session_state":input.sessionState,"source_count":input.context.sources.count,"personal_turn_count":input.input.userTurns.count,"reply_count":input.replies.count,"accepted_ai_parts":input.replies.reduce(0) { $0+$1.parts.filter { $0.kind == .aiSuggestion }.count }]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self));return
            } else if args[0] == "outcome-read" {
                guard args.count == 3 else { throw VoiceOSError("outcome-read requires conversation ID") }
                let rows=try await store.conversationOutcomes(conversationID:args[2])
                let output:[String:Any]=["integrity":try await store.integrityCheck(),"outcomes":rows.map { ["id":$0.id,"state":$0.state,"validity":$0.validity,"claim_ids":$0.claimIDs,"prior_claim_ids":$0.priorClaimIDs,"proposals":$0.proposals.count,"usage":$0.usage ?? [:]] as [String:Any] }]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self));return
            } else if args[0] == "discussion-read" {
                guard args.count == 3 else { throw VoiceOSError("discussion-read requires conversation ID") }
                let attempts = try await store.discussionAttempts(conversationID:args[2])
                let output:[String:Any] = ["integrity":try await store.integrityCheck(),"attempts":attempts.map { ["id":$0.id,"state":$0.state,"validity":$0.validity,"parts":$0.parts.count,"usage":$0.usage ?? [:]] as [String:Any] }]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self));return
            } else if args[0] == "conversation-read" {
                guard args.count == 3 else { throw VoiceOSError("conversation-read requires conversation ID") }
                let session = try await store.conversation(id:args[2]), turns = try await store.conversationUserTurns(conversationID:args[2])
                let output:[String:Any] = ["id":session.id,"state":session.state,"version":session.version,"validity":session.validity,"user_turns":turns.count,"integrity":try await store.integrityCheck()]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            } else if ["dictation-fixture","discussion-voice-fixture"].contains(args[0]) {
                let intent = try await store.beginDictation(commandID:"synthetic-dictation")
                let format = AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
                let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:12000)!; buffer.frameLength = 12000
                for i in 0..<12000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i)*0.1) }
                do { let file = try AVAudioFile(forWriting:intent.stagingURL,settings:format.settings); try file.write(from:buffer) }
                try await store.sealDictation(sourceID:intent.sourceID)
                if args[0] == "discussion-voice-fixture" { try await store.processTranscriptions(using:SyntheticDiscussionSpeech()) }
            } else if args[0] == "quiet-feedback-read" {
                let items = try await store.cognitiveFeedback(), pref = try await store.cognitiveFeedbackPreference()
                let output:[String:Any] = ["mode":pref.mode.rawValue,"version":pref.version,"items":items.map { ["id":$0.id,"attempt_id":$0.attemptID,"candidate_id":$0.hit.id] }]
                print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)); return
            } else if args[0] == "quiet-pause-fixture" {
                try await store.setCognitiveFeedbackMode(.paused,expectedVersion:0,commandID:"synthetic-quiet-pause")
            } else if args[0] == "quiet-ignore-fixture" {
                guard let item = try await store.cognitiveFeedback().first else { throw VoiceOSError("fixture requires an accepted current relevance receipt") }
                try await store.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id,commandID:"synthetic-quiet-ignore")
            } else if ["import", "import-personal-audio"].contains(args[0]) {
                guard args.count >= 3 else { throw VoiceOSError("missing file") }
                let file = URL(fileURLWithPath: args[2]), command = args.count > 3 ? args[3] : UUID().uuidString
                if args[0] == "import-personal-audio" {
                    _ = try await store.importPersonalAudio(file, commandID: command)
                } else { _ = try await store.importFile(file, commandID: command) }
            } else if args[0] == "expression-fixture" {
                _ = try await store.recordUserExpression("我会整理开发验证素材。以后也许研究检索。我现在不打算学习摄影。", commandID: "synthetic-expression")
            } else if args[0] == "extracted-action-fixture" {
                guard let source = try await store.sources().first(where: { $0.origin == "user" }) else { throw VoiceOSError("fixture requires user text") }
                let snapshot = try await store.prepareLocalTranscriptContext(sourceIDs: [source.id])
                let context = try await store.persistLocalContext(snapshot, commandID: "synthetic-action-context")
                let attempt = try await store.reserveLocalModelAttempt(contextID: context, model: "fixture", promptVersion: "v2", schemaVersion: "v2")
                let input = snapshot.sources[0]
                let refs = [ClaimReference(sourceID: source.id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)]
                _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [ClaimProposal(statement: "我会整理开发验证素材", ownership: .userTentative, references: refs, action: ExtractedAction(title: "整理开发验证素材", kind: .task, quote: "我会整理开发验证素材", autoSend: true))])
            } else if args[0] == "feedback-fixture" {
                guard let action = try await store.actions(includeHistory: true).first(where: { $0.kind == "task" }) else { throw VoiceOSError("fixture requires task") }
                _ = try await store.recordActionFeedback(actionID: action.id, expectedVersion: action.version, kind: .outcome, text: "合成结果验证：素材已整理，仅测试反馈回流。", commandID: "synthetic-feedback")
            } else if args[0] == "export" {
                guard args.count >= 3 else { throw VoiceOSError("export requires new package directory") }
                try await store.exportPackage(to: URL(fileURLWithPath: args[2]), includeMedia: args.count == 4 && args[3] == "media")
            } else if args[0] == "cognition-fixture" {
                guard let source = try await store.sources().first(where: { !($0.transcript ?? "").isEmpty }) else { throw VoiceOSError("test fixture requires an existing transcript") }
                let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source.id])
                let contextID = try await store.persistLocalContext(context, commandID: "local-cognition-fixture")
                let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "development-fixture", promptVersion: "fixture-v1", schemaVersion: "claims-v1")
                let input = context.sources[0]
                _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [ClaimProposal(statement: "开发测试候选，不代表模型理解结果或用户观点", ownership: .aiCandidate, references: [ClaimReference(sourceID: source.id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)])])
            } else if args[0] == "reminder-fixture" {
                guard let action = try await store.actions().first(where: { $0.kind == "task" }) else { throw VoiceOSError("fixture requires a task") }
                let port = FileRemindersFixture(file: URL(fileURLWithPath: args[1]).appendingPathComponent("fixture-reminders.json"))
                try await store.sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: "development-fixture-calendar", using: port)
            } else if args[0] == "reminder-read-fixture" {
                guard let link = try await store.reminderLinks().first else { throw VoiceOSError("fixture requires a reminder link") }
                let port = FileRemindersFixture(file: URL(fileURLWithPath: args[1]).appendingPathComponent("fixture-reminders.json"))
                try await store.readReminder(linkID: link.id, calendarID: "development-fixture-calendar", using: port)
            } else if args[0] == "action-fixture" {
                guard let claim = try await store.candidateClaims().first else { throw VoiceOSError("fixture requires a candidate") }
                _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: "开发验证任务，不代表真实用户任务", kind: .task, commandID: "fixture-action")
            } else if args[0] == "action-state-fixture" {
                guard let action = try await store.actions().first else { throw VoiceOSError("fixture requires an action") }
                _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .completed, commandID: "fixture-action-state")
            } else if args[0] == "review-fixture" {
                guard let claim = try await store.candidateClaims().first else { throw VoiceOSError("test fixture requires a current candidate") }
                _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: claim.reviewVersion, action: .endorse, commandID: "fixture-review")
            } else if args[0] == "policy-fixture" {
                guard let source = try await store.sources().first else { throw VoiceOSError("test fixture requires a source") }
                _ = try await store.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: !source.localOnly, commandID: "fixture-policy")
            } else if args[0] == "correction-fixture" {
                guard let source = try await store.sources().first(where: { $0.transcript != nil }), let version = source.transcriptVersionID else { throw VoiceOSError("test fixture requires a transcript") }
                _ = try await store.correctTranscript(sourceID: source.id, expectedVersionID: version, text: source.transcript! + "（开发故障验证注记）", commandID: "fixture-correction")
            } else if args[0] == "transcribe" { try await store.processTranscriptions(using: NativeSpeechPort()) }
            else if args[0] != "read" { throw VoiceOSError("unknown command") }
            let records = try await store.sources()
            // Deliberately omit paths, names and transcript contents from public diagnostics.
            let output: [String: Any] = ["integrity": try await store.integrityCheck(), "records": records.map {
                ["id": $0.id, "state": $0.state, "kind": $0.kind, "bytes": $0.bytes, "job_state": $0.jobState ?? "none", "text_scalars": $0.transcript?.unicodeScalars.count ?? 0] as [String: Any]
            }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}

// Development-only durable stand-in for an external service. Never uses EventKit.
private actor FileRemindersFixture: RemindersPort {
    let file: URL
    init(file: URL) { self.file = file }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ReminderSnapshot].self, from: Data(contentsOf: file)).filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String) async throws {
        guard !FileManager.default.fileExists(atPath: file.path) else { throw VoiceOSError("fixture must never duplicate a write") }
        let data = try JSONEncoder().encode([ReminderSnapshot(id: UUID().uuidString, title: title, completed: true, marker: marker)])
        try data.write(to: file, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
        let fd = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw VoiceOSError("fixture directory unavailable") }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw VoiceOSError("fixture directory sync failed") }
    }
}

private func runExpressionQueueFixture(_ store: VoiceOSStore, existingAudio: Bool = false) async throws {
    _ = try await store.recordUserExpression("合成历史表达：需要核对条件。", commandID: "queue-history")
    let current: String
    if existingAudio {
        guard let audio = try await store.sources().first(where: { $0.kind == "audio" && $0.origin == "user" && $0.speaker == "user" && !($0.transcript ?? "").isEmpty }) else { throw VoiceOSError("fixture requires transcribed personal audio") }
        current = audio.id
    } else { current = try await store.recordUserExpression("合成当前表达：请理解并关联这次文字。", commandID: "queue-current") }
    let configuration = ModelConfiguration(provider: "queue-fixture", model: "synthetic", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: current, cognition: configuration, association: configuration)
    let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "queue-processing", cognition: configuration, association: configuration)
    let result = try await store.runExpressionProcessingIntent(id: intent.id, retrieval: QueueFixtureRetrieval(), cognitionPort: QueueFixtureModel(configuration: configuration), associationPort: QueueFixtureAssociation(configuration: configuration))
    let output:[String:Any] = ["integrity":try await store.integrityCheck(),"intent_id":result.id,"state":result.state.rawValue,"phase":result.phase.rawValue]
    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
}

private struct QueueFixtureRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID: $0.id, score: 1, method: "exact") }
    }
}
private struct QueueFixtureModel: ModelPort {
    let configuration: ModelConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(status: .completed, claims: [], inputTokens: 2, outputTokens: 1)
    }
}
private struct QueueFixtureAssociation: ExpressionAssociationPort {
    let configuration: ModelConfiguration
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        ExpressionAssociationResponse(proposals: [], inputTokens: 2, outputTokens: 1)
    }
}

private struct LocalDiscussionFixture: DiscussionModelPort {
    var cited=true
    let configuration = ModelConfiguration(provider:"fixture",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        let source=request.snapshot.context.sources[0]
        let ref=ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)
        return DiscussionModelResponse(status:.completed,parts:[DiscussionPart(kind:.quotation,text:source.text,references:[ref]),DiscussionPart(kind:.aiSuggestion,text:"合成AI建议：比较反例，尚未形成用户结论。",references:cited ? [ref] : [])],inputTokens:11,outputTokens:5)
    }
}

private struct SyntheticDiscussionSpeech: SpeechPort {
    let backendIdentity="synthetic-discussion-speech-fixture-v1"
    func transcribe(_ url:URL,locale:String) async throws -> SpeechText {
        SpeechText(text:"合成语音链路夹具：条件尚未验证，暂不执行任务。")
    }
}

private struct LocalOutcomeFixture:ConversationOutcomePort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"outcome",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func extract(_ request:ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        let turn=request.snapshot.input.userTurns.last!,source=request.snapshot.context.sources.first { $0.sourceID == turn.sourceID }!,ref=ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id),reply=request.snapshot.replies.last!
        return ConversationOutcomeResponse(status:.completed,proposals:[
            .init(statement:"我会整理开发验证素材",ownership:.userTentative,sourceEvidence:[.init(reference:ref,quote:"我会整理开发验证素材")],action:.init(title:"整理开发验证素材",kind:.task,quote:"我会整理开发验证素材",autoSend:true)),
            .init(statement:reply.parts[1].text,ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[.init(attemptID:reply.attemptID,partIndex:1,quote:reply.parts[1].text)],action:.init(title:"比较反例",kind:.aiSuggestion,quote:"比较反例"))],inputTokens:12,outputTokens:6)
    }
}

private func runRecordingRequestFixture(_ store: VoiceOSStore, seed: Bool) async throws {
    let configuration = ModelConfiguration(provider:"queue-fixture",model:"synthetic",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    if seed {
        _ = try await store.recordUserExpression("合成历史表达：整理测试资料时核对条件。",commandID:"synthetic-record-history")
        let intent = try await store.beginProcessingDictation(commandID:"synthetic-record-processing",cognition:configuration,association:configuration)
        let format = AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:12000)!; buffer.frameLength = 12000
        for i in 0..<12000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i)*0.1) }
        do { let file = try AVAudioFile(forWriting:intent.stagingURL,settings:format.settings); try file.write(from:buffer) }
        try await store.sealDictation(sourceID:intent.sourceID)
    }
    try await store.processTranscriptions(using:SyntheticDiscussionSpeech())
    try await store.reconcileRecordingProcessingRequests(cognition:configuration,association:configuration)
    for queue in try await store.processingIntents() where queue.state == .queued {
        _ = try await store.runExpressionProcessingIntent(id:queue.id,retrieval:QueueFixtureRetrieval(),cognitionPort:QueueFixtureModel(configuration:configuration),associationPort:QueueFixtureAssociation(configuration:configuration))
    }
    let requests = try await store.recordingProcessingRequests()
    let output:[String:Any] = ["integrity":try await store.integrityCheck(),"requests":requests.map { ["id":$0.id,"state":$0.state,"queue_id":$0.processingIntentID ?? ""] },"queue_states":try await store.processingIntents().map { $0.state.rawValue },"queue_count":try await store.processingIntents().count,"model_count":try await store.modelAttempts().count,"association_count":try await store.expressionAssociationAttempts().count]
    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
}

private struct LocalSegmentFixture: SegmentExtractionPort {
    let configuration: ModelConfiguration
    let empty: Bool
    func extract(_ request: SegmentExtractionRequest) async throws -> SegmentExtractionResponse {
        if empty { return .init(proposals:[]) }
        let s = request.segment
        return .init(proposals:[.init(kind:s.ordinal == 1 ? .possibleAction:.negation,statement:"合成片段证据，尚未聚合",quote:s.text,
            textStart:s.textStart,textEnd:s.textEnd,spanIDs:s.references.map(\.spanID))],inputTokens:10,outputTokens:3)
    }
}
private func runSegmentExtractionFixture(_ store: VoiceOSStore,args: [String]) async throws {
    var selected: String?
    if args[0] == "segment-extraction-fixture" {
        let c = ModelConfiguration(provider:"local_segment_fixture",model:"synthetic",promptVersion:"v1",schemaVersion:"v1",destination:.local)
        let source = try await store.recordUserExpression(String(repeating:"合成原话。",count:20),commandID:"segment-extraction-source")
        let scope = try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:c,aggregation:c,segmentScalarBudget:20)
        let batch = try await store.enqueueSegmentedProcessingBatch(scope,commandID:"segment-extraction-command",extraction:c,aggregation:c)
        selected = batch.id
    } else if args[0] == "segment-extraction-personal-fixture" {
        guard args.count == 3 else { throw VoiceOSError("personal fixture requires explicit existing batch ID") }
        selected = args[2]
    }
    if let selected {
        let batch = try await store.segmentedProcessingBatch(id:selected), identity = batch.scope.extraction
        guard identity.destination == .local, ["local_segment_fixture","local_batch_inspection"].contains(identity.provider), ["synthetic","no-dispatch"].contains(identity.model) else { throw VoiceOSError("fixture requires explicit local fixture identity") }
        let c = ModelConfiguration(provider:identity.provider,model:identity.model,promptVersion:identity.promptVersion,schemaVersion:identity.schemaVersion,destination:identity.destination)
        let port = LocalSegmentFixture(configuration:c,empty:args[0] == "segment-extraction-personal-fixture")
        for _ in batch.scope.plan.segments { guard try await store.runNextSegmentExtraction(batchID:selected,using:port) != nil else { break } }
    }
    var summaries: [[String:Any]] = []
    for batch in try await store.segmentedProcessingBatches() {
        let receipts = try await store.segmentExtractionAttempts(batchID:batch.id)
        var ready = false, digest: String?
        if batch.state == .queued, receipts.count == batch.scope.plan.segments.count, receipts.allSatisfy({ $0.state == .completed && $0.validity == "current" }) {
            let e = batch.scope.extraction, a = batch.scope.aggregation
            let ledger = try await store.preparePersistedSegmentedEvidenceLedger(batchID:batch.id,
                extraction:.init(provider:e.provider,model:e.model,promptVersion:e.promptVersion,schemaVersion:e.schemaVersion,destination:e.destination),
                aggregation:.init(provider:a.provider,model:a.model,promptVersion:a.promptVersion,schemaVersion:a.schemaVersion,destination:a.destination))
            ready = !ledger.requiresBoundaryResolution; digest = ledger.contentDigest
        }
        summaries.append(["id":batch.id,"state":batch.state.rawValue,"segment_count":batch.scope.plan.segments.count,"evidence_ready":ready,"ledger_digest":digest ?? "",
            "attempts":receipts.map { ["id":$0.id,"state":$0.state.rawValue,"validity":$0.validity,"sequence":$0.producerSequence,"segment_id":$0.request.segment.id] }])
    }
    let output:[String:Any] = ["integrity":try await store.integrityCheck(),"batches":summaries,"old_model_count":try await store.modelAttempts().count,"action_count":try await store.actions().count,"claim_count":try await store.candidateClaims().count]
    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
}

private struct EmptyPersonalAggregation: SegmentAggregationPort {
    let configuration: ModelConfiguration
    func aggregate(_ request: SegmentAggregationRequest) async throws -> SegmentAggregationResponse {
        guard request.ledger.evidence.isEmpty else { throw VoiceOSError("empty personal fixture cannot judge actual proposals") }
        return .init(review:.init(batchID:request.batchID,ledgerDigest:request.ledger.contentDigest,reviewedEvidenceIDs:[],actionDecisions:[]),finalClaims:[])
    }
}
private func runPersonalSegmentCognition(_ store: VoiceOSStore,args: [String]) async throws {
    guard args.count == 3 else { throw VoiceOSError("personal cognition fixture requires explicit batch ID") }
    let batch=try await store.segmentedProcessingBatch(id:args[2]),e=batch.scope.extraction,a=batch.scope.aggregation
    guard [e,a].allSatisfy({ $0.destination == .local && $0.provider == "local_batch_inspection" && $0.model == "no-dispatch" }) else { throw VoiceOSError("fixture must keep explicit non-network identities") }
    let config: (ProcessingModelIdentity)->ModelConfiguration = { .init(provider:$0.provider,model:$0.model,promptVersion:$0.promptVersion,schemaVersion:$0.schemaVersion,destination:$0.destination) }
    let result=try await store.processSegmentedCognition(batchID:batch.id,extraction:LocalSegmentFixture(configuration:config(e),empty:true),aggregation:EmptyPersonalAggregation(configuration:config(a)))
    let attempt=try await store.segmentAggregationAttempt(batchID:batch.id)
    let output: [String:Any]=["batch_id":batch.id,"parent_state":result.state.rawValue,"cognition_saved":result.claimIDs != nil,"claim_count":result.claimIDs?.count ?? 0,
        "aggregation_id":attempt?.id ?? "","aggregation_state":attempt?.state.rawValue ?? "","aggregation_validity":attempt?.validity ?? "",
        "action_count":try await store.actions().count,"integrity":try await store.integrityCheck(),"semantic_quality_tested":false,"network_calls":0]
    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
}
