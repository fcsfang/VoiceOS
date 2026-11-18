import XCTest
@testable import VoiceOSCore

final class WorkspaceBodyReadChecks: XCTestCase {
    private let materialFilters = ["日常材料", "未读", "在读", "已归档", "回收站"]

    private func source(_ id: String, createdAt: String = "2026-04-01T00:00:00Z",
                        state: String = "saved", jobState: String? = "completed",
                        transcript: String? = nil, localOnly: Bool = false,
                        presentation: RecordingPresentation? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: state, kind: "user_text",
                     createdAt: createdAt, bytes: 1, duration: nil, jobState: jobState,
                     transcript: transcript ?? "原话 " + id, error: nil, relativePath: "assets/" + id,
                     transcriptVersionID: "t-" + id, transcriptionBackend: nil, spans: [],
                     localOnly: localOnly, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                     feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private func claim(_ id: String, sourceIDs: [String], validity: String = "current",
                       reviewState: String = "pending") -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: "理解 " + id, ownership: "user_tentative",
                       evidenceState: "unverified", validity: validity,
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: 1, reviewState: reviewState)
    }

    private func action(_ id: String, claimID: String, parent: String? = nil,
                        state: String = "open", validity: String = "current",
                        version: Int = 1) -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: 1, title: "待办 " + id, kind: "task",
                     intentActor: "user", note: "", state: state, validity: validity, version: version,
                     autoSend: true, intent: ActionIntentMetadata(intentType: "task", followupState: "pending", uncertain: false),
                     commandID: "test:" + id, createdAt: "2026-01-01T00:00:00Z", parentID: parent)
    }

    private func expression(_ id: String, sourceIDs: [String]) -> RecordingPresentation {
        var presentation = RecordingPresentation()
        presentation.expression = RecordingExpression(
            id: id, sourceIDs: sourceIDs, title: "分组 " + id, summary: "摘要", reason: "依据",
            responseIDs: ["response"],
            versions: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, "t-" + $0) }),
            policies: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, 1) }),
            state: "completed", previousActionIDs: [])
        return presentation
    }

    private func reviewPresentation(_ id: String, issueCount: Int) -> RecordingPresentation {
        var presentation = RecordingPresentation()
        let issues = (0..<issueCount).map { TranscriptionReview.Issue(span_id: "span-\($0)", reason: "疑点 \($0)") }
        presentation.transcriptionReview = TranscriptionReview(
            completed: true, changed: false, response_id: "review", response_ids: ["review"],
            context_review_version: 3, corrections: [], unresolved_issues: issues,
            transcriptVersionID: "t-" + id, scope: "complete_expression_knowledge_and_intent",
            full_text_independent_passes: 1, review_method: "direct_ai")
        presentation.transcriptVersionID = "t-" + id
        return presentation
    }

    private let modelIdentity = ProcessingModelIdentity(
        ModelConfiguration(provider: "fixture", model: "body", promptVersion: "v1", schemaVersion: "v1", destination: .local))

    private func context(sourceID: String) -> LocalTranscriptContext {
        let item = ContextTranscript(sourceID: sourceID, sourceVersionID: "v-" + sourceID,
                                     transcriptVersionID: "t-" + sourceID, origin: "user", speaker: "user",
                                     localOnly: false, text: "原话 " + sourceID, spans: [])
        return LocalTranscriptContext(sources: [item], scalarBudget: 4000, contentDigest: "digest-" + sourceID)
    }

    private func intent(_ index: Int, sourceID: String, state: ExpressionProcessingIntentState,
                        policyVersion: Int = 1, ignored: Bool = false) -> ExpressionProcessingIntentRecord {
        let snapshot = ExpressionProcessingIntentSnapshot(
            id: "snapshot-\(index)", context: context(sourceID: sourceID), policyVersion: policyVersion,
            cognition: modelIdentity, association: modelIdentity, contentDigest: "digest-\(index)")
        return ExpressionProcessingIntentRecord(
            id: "intent-\(index)", commandID: "command-\(index)", sourceID: sourceID, snapshot: snapshot,
            state: state, phase: .cognition, cognitionAttemptID: nil, associationAttemptID: nil,
            error: nil, cancelReason: nil, ignoredAt: ignored ? "2026-01-01T00:00:00Z" : nil,
            ignoreReason: nil, supersededBy: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }

    func testMaterialPageMatchesDirectReadsAndCounts() {
        var presentations: [String: RecordingPresentation] = [:]
        for start in stride(from: 0, to: 319, by: 25) {
            let grouped = expression("expression-\(start)", sourceIDs: ["src-\(start)", "src-\(start + 1)"])
            presentations["src-\(start)"] = grouped
            presentations["src-\(start + 1)"] = grouped
        }
        for start in stride(from: 0, to: 319, by: 40) {
            var paired = presentations["src-\(start)"] ?? RecordingPresentation()
            paired.recordingContext = RecordingContext(
                personalSourceID: "src-\(start)", externalSourceID: "src-\(start + 1)", sessionID: "pair",
                offsetMS: 0, personalVersionID: "t-src-\(start)", externalVersionID: "t-src-\(start + 1)",
                personalPolicyVersion: 1, externalPolicyVersion: 1)
            presentations["src-\(start)"] = paired
        }
        for offset in stride(from: 0, to: 320, by: 29) {
            var archived = presentations["src-\(offset)"] ?? RecordingPresentation()
            archived.archived = true
            presentations["src-\(offset)"] = archived
        }
        let records = (0..<320).map { offset in
            let id = "src-\(offset)"
            return source(id, state: offset % 17 == 0 ? "trashed" : "saved",
                          transcript: offset % 31 == 0 ? "" : nil,
                          presentation: presentations[id])
        }
        let catalog = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let index = SourcePageIndex(records: records)
        var readingStates: [String: SourceReadingState] = [:]
        for offset in 0..<320 {
            switch offset % 5 {
            case 1: readingStates["src-\(offset)"] = .reading
            case 2: readingStates["src-\(offset)"] = .read
            default: break
            }
        }

        func directContextID(_ source: SourceRecord) -> String? {
            guard let pair = source.presentation?.recordingContext, pair.personalSourceID == source.id,
                  let external = catalog[pair.externalSourceID], !source.localOnly, !external.localOnly,
                  !source.needsTranscriptionReview, !external.needsTranscriptionReview,
                  source.transcriptVersionID == pair.personalVersionID,
                  external.transcriptVersionID == pair.externalVersionID,
                  source.policyVersion == pair.personalPolicyVersion,
                  external.policyVersion == pair.externalPolicyVersion else { return nil }
            return external.id
        }
        func directRows(_ filter: String) -> [SourceRecord] {
            let selected = records.filter { source in
                switch filter {
                case "回收站": return source.isTrashed
                case "已归档": return source.isArchived
                case "未读": return !source.isArchived && !source.isTrashed && (readingStates[source.id] ?? .unread) == .unread
                case "在读": return !source.isArchived && !source.isTrashed && readingStates[source.id] == .reading
                default: return !source.isArchived && !source.isTrashed
                }
            }
            let selectedIDs = Set(selected.map(\.id))
            let attached = Set(selected.compactMap { directContextID($0) }).intersection(selectedIDs)
            let entries = selected.compactMap { source -> (SourceRecord, String)? in
                guard !attached.contains(source.id) else { return nil }
                guard let expression = source.recordingExpression(in: catalog), expression.sourceIDs.count > 1,
                      Set(expression.sourceIDs).isSubset(of: selectedIDs) else { return (source, source.createdAt) }
                guard expression.sourceIDs.first == source.id else { return nil }
                return (source, expression.sourceIDs.compactMap { catalog[$0]?.createdAt }.max() ?? source.createdAt)
            }
            return entries.sorted { $0.1 > $1.1 }.map(\.0)
        }
        func page(_ filter: String) -> MaterialReadingPage {
            MaterialReadingPage(records: records, filter: filter, filters: materialFilters,
                                readingStates: readingStates, catalog: catalog,
                                expressions: index.expressionsBySourceID)
        }

        for filter in materialFilters {
            let built = page(filter)
            XCTAssertEqual(built.rows.map(\.id), directRows(filter).map(\.id), "材料页 \(filter) 行顺序必须与直算一致")
        }
        for filter in materialFilters {
            XCTAssertEqual(page(filter).counts[filter], directRows(filter).count, "材料页 \(filter) 计数必须与直算一致")
        }

        let clock = ContinuousClock()
        let passes = 4
        var directWork = 0, indexWork = 0
        var direct: [Double] = [], indexed: [Double] = []
        for _ in 0..<5 {
            direct.append(seconds(clock.measure {
                for _ in 0..<passes {
                    for filter in materialFilters { directWork += directRows(filter).count }
                }
            }))
            indexed.append(seconds(clock.measure {
                for _ in 0..<passes {
                    indexWork += page(materialFilters[0]).counts.values.reduce(0, +)
                }
            }))
        }
        XCTAssertEqual(directWork, indexWork, "材料页一次构建与逐过滤器直算的工作量必须相等")
        let directMedian = median(direct), indexMedian = median(indexed)
        print("material page: direct=\(directMedian)s indexed=\(indexMedian)s (5 alternating rounds)")
        XCTAssertLessThan(indexMedian, directMedian, "材料页一次构建必须快于每 body 逐过滤器重算")
    }

    func testTopicReadingDataMatchesDirectFiltersAndSections() {
        let records = (0..<240).map { source("src-\($0)") }
        let sections = (0..<6).map { section in
            TopicReadingSection(
                id: "section-\(section)", title: "小主题 \(section)", summary: "摘要",
                claimIDs: (0..<20).map { "claim-\(section * 20 + $0)" },
                actionIDs: (0..<10).map { "action-\(section * 10 + $0)" },
                evidence: [])
        }
        let summary = TopicOrganizationSummary(
            summary: "主题", questions: [], sourceVersions: [:], policyVersions: [:],
            responseID: "response", sections: sections)
        let topic = ReflectionQuestion(id: "topic-0", title: "主题", sourceID: "src-0",
                                       createdAt: "2026-01-01T00:00:00Z",
                                       updatedAt: "2026-01-02T00:00:00Z", organization: summary)
        var claims = (0..<200).map {
            claim("claim-\($0)", sourceIDs: ["src-\($0)"],
                  validity: $0 % 17 == 0 ? "frozen" : "current",
                  reviewState: $0 % 19 == 0 ? "rejected" : "pending")
        }
        claims.append(claim("claim-unused", sourceIDs: ["src-1"]))
        var actions = (0..<60).map {
            action("action-\($0)", claimID: "claim-\($0)",
                   state: $0 % 13 == 0 ? "dismissed" : "open",
                   validity: $0 % 11 == 0 ? "frozen" : "current",
                   version: $0 % 3 + 1)
        }
        actions.append(action("action-unused", claimID: "claim-0"))
        let sourceIDs = Set((0..<200).map { "src-\($0)" })
        let data = TopicReadingData(topic: topic, sourceIDs: sourceIDs, records: records,
                                    claims: claims, actions: actions)

        XCTAssertEqual(data.sources.map(\.id), records.filter { sourceIDs.contains($0.id) }.map(\.id),
                       "主题材料必须保持资料库顺序")
        for section in sections {
            let directClaims = claims.filter {
                section.claimIDs.contains($0.id) && $0.validity == "current" && $0.reviewState != "rejected"
            }
            XCTAssertEqual(data.sectionClaims[section.id]?.map(\.id) ?? [], directClaims.map(\.id),
                           "小主题 \(section.id) 的观点必须与直算一致且保持顺序")
            let directActions = actions.filter {
                section.actionIDs.contains($0.id) && $0.validity == "current" && $0.state != "dismissed"
            }
            XCTAssertEqual(data.sectionActions[section.id]?.map(\.id) ?? [], directActions.map(\.id),
                           "小主题 \(section.id) 的行动必须与直算一致且保持顺序")
            XCTAssertEqual(data.sectionPosition[section.id], sections.firstIndex { $0.id == section.id },
                           "小主题 \(section.id) 的位置必须与结构顺序一致")
        }
        XCTAssertEqual(data.unlinkedSources.map(\.id),
                       records.filter { !sourceIDs.contains($0.id) && !$0.isTrashed && !($0.transcript ?? "").isEmpty }.map(\.id),
                       "未关联材料必须与直算一致")

        let topicSources = [
            "topic-0": Array(sourceIDs),
            "topic-1": Array((0..<100).map { "src-\($0)" }),
            "topic-2": Array((0..<120).map { "src-\($0)" }),
            "topic-3": Array((80..<200).map { "src-\($0)" }),
            "topic-4": Array((0..<30).map { "src-\($0)" }),
        ]
        let topics = topicSources.keys.sorted().map {
            ReflectionQuestion(id: $0, title: $0, sourceID: "src-0", createdAt: "", updatedAt: "")
        }
        let counts = TopicAdjacency.sharedCounts(selectedTopicID: "topic-0", selectedSourceIDs: sourceIDs,
                                                 topics: topics, topicSources: topicSources)
        var expected: [String: Int] = [:]
        for topic in topics where topic.id != "topic-0" {
            let shared = Set(topicSources[topic.id] ?? []).intersection(sourceIDs).count
            if shared > 0 { expected[topic.id] = shared }
        }
        XCTAssertEqual(counts, expected, "相邻主题共享材料数必须与逐主题求交一致")

        let clock = ContinuousClock()
        let passes = 5
        var directWork = 0, indexWork = 0
        var direct: [Double] = [], indexed: [Double] = []
        for _ in 0..<5 {
            direct.append(seconds(clock.measure {
                for _ in 0..<passes {
                    for section in sections {
                        directWork += claims.filter {
                            section.claimIDs.contains($0.id) && $0.validity == "current" && $0.reviewState != "rejected"
                        }.count
                        directWork += actions.filter {
                            section.actionIDs.contains($0.id) && $0.validity == "current" && $0.state != "dismissed"
                        }.count
                    }
                }
            }))
            indexed.append(seconds(clock.measure {
                for _ in 0..<passes {
                    let built = TopicReadingData(topic: topic, sourceIDs: sourceIDs, records: records,
                                                 claims: claims, actions: actions)
                    for section in sections {
                        indexWork += built.sectionClaims[section.id]?.count ?? 0
                        indexWork += built.sectionActions[section.id]?.count ?? 0
                    }
                }
            }))
        }
        XCTAssertEqual(directWork, indexWork, "主题页卡片集合与逐卡片过滤的工作量必须相等")
        let directMedian = median(direct), indexMedian = median(indexed)
        print("topic cards: direct=\(directMedian)s indexed=\(indexMedian)s (5 alternating rounds)")
        XCTAssertLessThan(indexMedian, directMedian, "主题页索引读必须快于每张卡片重新过滤")
    }

    func testSourcePageIndexAttentionAndActionReadsMatchDirectScans() {
        var records: [SourceRecord] = []
        for offset in 0..<500 {
            let id = "src-\(offset)"
            let presentation = offset % 7 == 0 && offset % 13 != 0
                ? reviewPresentation(id, issueCount: offset % 4 + 1) : nil
            let state = offset % 71 == 0 ? "interrupted" : offset % 53 == 0 ? "trashed" : "saved"
            let jobState = offset % 41 == 0 ? "failed" : offset % 47 == 0 ? "blocked" : "completed"
            records.append(source(id, state: state, jobState: jobState,
                                  transcript: offset % 37 == 0 ? "" : nil, presentation: presentation))
        }
        let actions = (0..<120).map {
            action("action-\($0)", claimID: "claim-\($0)",
                   parent: $0 % 3 == 0 ? "goal-\($0 % 7)" : nil,
                   state: $0 % 17 == 0 ? "completed" : "open",
                   validity: $0 % 19 == 0 ? "frozen" : "current",
                   version: $0 % 5 + 1)
        }
        let index = SourcePageIndex(records: records, actions: actions)

        func directPoints() -> [WorkspaceTranscriptReviewPoint] {
            records.compactMap { source -> WorkspaceTranscriptReviewPoint? in
                guard !source.isTrashed, !source.isArchived else { return nil }
                let count = source.unresolvedTranscriptionIssueCount
                guard count > 0 else { return nil }
                return WorkspaceTranscriptReviewPoint(source: source, count: count)
            }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.source.displayTitle < $1.source.displayTitle }
        }
        XCTAssertEqual(index.transcriptReviewPoints.map(\.id), directPoints().map(\.id),
                       "疑点材料列表必须与直算一致")
        XCTAssertEqual(index.transcriptReviewPoints.map(\.count), directPoints().map(\.count),
                       "疑点计数必须与直算一致")
        XCTAssertEqual(index.nextStepCounts, ActionRowLayout.nextStepCounts(actions),
                       "下一步计数必须与直算一致")
        XCTAssertEqual(index.actionRevisionKey,
                       actions.map { $0.id + String($0.version) + $0.state + $0.validity }.joined(separator: "|"),
                       "行动修订键必须与直算一致")
        let directNeedsAttention = records.contains {
            ["failed", "blocked"].contains($0.jobState ?? "") || ["interrupted", "quarantined"].contains($0.state)
        } || records.contains { $0.needsEmptyTranscriptionReview }
        XCTAssertEqual(index.recordsNeedAttention, directNeedsAttention,
                       "材料注意力门槛必须与直算一致")
        let chosenIDs = Set(actions.prefix(40).map(\.id))
        XCTAssertEqual(index.currentActionKeys(for: chosenIDs),
                       actions.filter { chosenIDs.contains($0.id) && $0.validity == "current" && $0.state != "dismissed" }
                           .map { $0.id + String($0.version) },
                       "主题加载键必须与直算一致且保持行动顺序")

        let catalog = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var intents: [ExpressionProcessingIntentRecord] = []
        for offset in 0..<200 {
            let state: ExpressionProcessingIntentState = offset % 5 == 0 ? .completed
                : offset % 7 == 0 ? .blocked : .queued
            intents.append(intent(offset, sourceID: "src-\(offset % 500)", state: state,
                                  policyVersion: offset % 9 == 0 ? 2 : 1,
                                  ignored: offset % 11 == 0))
        }
        func directIntents() -> [ExpressionProcessingIntentRecord] {
            intents.filter { intent in
                guard !intent.isDismissed, ![.completed, .cancelled, .frozen].contains(intent.state),
                      let input = intent.snapshot.context.sources.first else { return false }
                return records.contains {
                    $0.id == input.sourceID && $0.transcriptVersionID == input.transcriptVersionID
                        && $0.policyVersion == intent.snapshot.policyVersion
                }
            }
        }
        XCTAssertEqual(UnfinishedProcessingIntents.filter(intents, recordsByID: catalog).map(\.id),
                       directIntents().map(\.id), "未完成意图必须与逐意图扫库一致")

        let clock = ContinuousClock()
        let passes = 5
        var directWork = 0, indexWork = 0
        var direct: [Double] = [], indexed: [Double] = []
        for _ in 0..<5 {
            direct.append(seconds(clock.measure {
                for _ in 0..<passes {
                    directWork += directIntents().count
                    directWork += directPoints().count
                }
            }))
            indexed.append(seconds(clock.measure {
                for _ in 0..<passes {
                    indexWork += UnfinishedProcessingIntents.filter(intents, recordsByID: catalog).count
                    indexWork += index.transcriptReviewPoints.count
                }
            }))
        }
        XCTAssertEqual(directWork, indexWork, "注意力读取的工作量必须相等")
        let directMedian = median(direct), indexMedian = median(indexed)
        print("attention reads: direct=\(directMedian)s indexed=\(indexMedian)s (5 alternating rounds)")
        XCTAssertLessThan(indexMedian, directMedian, "注意力快照读必须快于每次 body 扫库")
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
