import XCTest
@testable import VoiceOSCore

final class RecentContentHomeSnapshotChecks: XCTestCase {
    private func source(_ id: String, createdAt: String, transcript: String = "原话内容",
                        feedbackKind: String? = nil, feedbackActionID: String? = nil,
                        feedbackRelation: String? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text", createdAt: createdAt,
                     bytes: 1, duration: nil, jobState: "completed", transcript: transcript, error: nil,
                     relativePath: "assets/" + id, transcriptVersionID: "t-" + id, transcriptionBackend: nil,
                     spans: [], localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: feedbackActionID, feedbackActionVersion: feedbackActionID == nil ? nil : 1,
                     feedbackKind: feedbackKind, feedbackRelation: feedbackRelation,
                     timeZone: "Asia/Shanghai", presentation: nil)
    }

    private func claim(_ id: String, sourceIDs: [String], statement: String) -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: statement, ownership: "user_tentative",
                       evidenceState: "unverified", validity: "current",
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: 1, reviewState: "pending")
    }

    private func action(_ id: String, claimID: String, title: String, state: String = "open",
                        validity: String = "current", kind: String = "task") -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: 1, title: title, kind: kind,
                     intentActor: "user", note: "", state: state, validity: validity, version: 1,
                     autoSend: true, intent: nil)
    }

    func testSnapshotMatchesDirectIndexAndDigestBuild() {
        let sources = [
            source("s1", createdAt: "2024-05-01T10:00:00Z"),
            source("s2", createdAt: "2024-05-01T11:00:00Z"),
            source("s3", createdAt: "2024-05-02T09:00:00Z"),
            source("s4", createdAt: "2024-05-02T12:00:00Z", transcript: "反馈原话", feedbackKind: "done"),
        ]
        let claims = [
            claim("c1", sourceIDs: ["s1"], statement: "【观点】完成比完美更重要"),
            claim("c2", sourceIDs: ["s1"], statement: "【长期目标】每周复盘一次"),
            claim("c3", sourceIDs: ["s2"], statement: "【观点】与父母长谈很愉快"),
            claim("c4", sourceIDs: ["s3"], statement: "整理桌面"),
        ]
        let actions = [
            action("a1", claimID: "c1", title: "整理桌面"),
            action("a2", claimID: "c1", title: "已经完成的事", state: "done"),
            action("a3", claimID: "c1", title: "已经失效的事", validity: "frozen"),
            action("a4", claimID: "c3", title: "不是任务的想法", kind: "note"),
            action("a5", claimID: "c1", title: "打磨汇报"),
        ]

        let snapshot = RecentContentHomeSnapshot.build(sources: sources, claims: claims, actions: actions)
        XCTAssertEqual(snapshot.days, RecentContentIndex.build(sources: sources, claims: claims))

        let items = snapshot.days.flatMap(\.items)
        let material = items.filter { $0.kind == .material }
        let feedback = items.filter { $0.kind == .feedback }
        XCTAssertEqual(Set(material.map(\.id)), ["s1", "s2", "s3"])
        XCTAssertEqual(feedback.count, 1)
        XCTAssertEqual(snapshot.digests.count, material.count)

        let plannedTasks = [RecentContentTask(id: "a1", title: "整理桌面"),
                            RecentContentTask(id: "a5", title: "打磨汇报")]
        for item in material {
            let tasks = item.id == "s1" ? plannedTasks : []
            XCTAssertEqual(snapshot.digests[item.id],
                           RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration, tasks: tasks),
                           item.id)
        }
        XCTAssertEqual(snapshot.digests["s1"]?.tasks.map(\.id), ["a1", "a5"])
        for item in feedback {
            XCTAssertNil(snapshot.digests[item.id], "feedback items carry no digest")
        }
    }

    func testFeedbackGroupsShowTaskProgressWithResolvedTaskContext() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sources = [
            source("f1", createdAt: "2024-05-01T10:00:00Z", transcript: "桌面已经整理完一半",
                   feedbackKind: "reflection", feedbackActionID: "a1", feedbackRelation: "progress"),
            source("f2", createdAt: "2024-05-01T11:00:00Z", transcript: "又想起要汇报",
                   feedbackKind: "reflection", feedbackActionID: "a2", feedbackRelation: "repeat"),
        ]
        let actions = [
            action("a1", claimID: "c1", title: "整理桌面"),
            action("a2", claimID: "c1", title: "打磨汇报"),
        ]

        let snapshot = RecentContentHomeSnapshot.build(sources: sources, claims: [], actions: actions, calendar: calendar)

        let feedback = snapshot.days.flatMap(\.items).filter { $0.kind == .feedback }
        XCTAssertEqual(feedback.map(\.title), ["任务进展"])
        let rows = feedback.first.flatMap { snapshot.progressRows[$0.id] }
        XCTAssertEqual(rows?.map(\.id), ["f2", "f1"])
        XCTAssertEqual(rows?.map(\.actionID), ["a2", "a1"])
        XCTAssertEqual(rows?.map(\.taskTitle), ["打磨汇报", "整理桌面"])
        XCTAssertEqual(rows?.map(\.relationLabel), ["再次提及", "实际进展"])
        XCTAssertEqual(rows?.map(\.text), ["又想起要汇报", "桌面已经整理完一半"])
        XCTAssertEqual(rows?.map(\.isTaskAvailable), [true, true])
    }

    func testFeedbackProgressRowsGroupByDayAndMarkMissingTasks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sources = [
            source("f1", createdAt: "2024-05-01T10:00:00Z", transcript: "第一天的反馈",
                   feedbackKind: "reflection", feedbackActionID: "a1", feedbackRelation: "repeat"),
            source("f2", createdAt: "2024-05-02T10:00:00Z", transcript: "第二天的反馈",
                   feedbackKind: "outcome", feedbackActionID: "gone"),
        ]

        let snapshot = RecentContentHomeSnapshot.build(sources: sources, claims: [],
                                                       actions: [action("a1", claimID: "c1", title: "整理桌面")],
                                                       calendar: calendar)

        XCTAssertEqual(snapshot.days.map(\.id), ["2024-05-02", "2024-05-01"])
        let feedback = snapshot.days.flatMap(\.items).filter { $0.kind == .feedback }
        XCTAssertEqual(feedback.map(\.title), ["任务进展", "任务进展"])

        let newer = feedback.first.flatMap { snapshot.progressRows[$0.id] }?.first
        XCTAssertEqual(newer?.taskTitle, "任务已不可用")
        XCTAssertEqual(newer?.relationLabel, "实际结果")
        XCTAssertEqual(newer?.text, "第二天的反馈")
        XCTAssertEqual(newer?.isTaskAvailable, false)

        let older = feedback.last.flatMap { snapshot.progressRows[$0.id] }?.first
        XCTAssertEqual(older?.taskTitle, "整理桌面")
        XCTAssertEqual(older?.relationLabel, "再次提及")
        XCTAssertEqual(older?.text, "第一天的反馈")
        XCTAssertEqual(older?.isTaskAvailable, true)
    }
}
