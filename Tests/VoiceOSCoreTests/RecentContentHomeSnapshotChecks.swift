import XCTest
@testable import VoiceOSCore

final class RecentContentHomeSnapshotChecks: XCTestCase {
    private func source(_ id: String, createdAt: String, transcript: String = "原话内容",
                        feedbackKind: String? = nil, feedbackActionID: String? = nil,
                        feedbackRelation: String? = nil, localOnly: Bool = false,
                        jobState: String = "completed") -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text", createdAt: createdAt,
                     bytes: 1, duration: nil, jobState: jobState, transcript: transcript, error: nil,
                     relativePath: "assets/" + id, transcriptVersionID: "t-" + id, transcriptionBackend: nil,
                     spans: [], localOnly: localOnly, policyVersion: 1, origin: "user", speaker: "user",
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
                     autoSend: true, intent: nil, commandID: "test:" + id, createdAt: "2026-01-01T00:00:00Z", parentID: nil)
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

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ date: Date, items: [RecentContentItem]) -> RecentContentDay {
        RecentContentDay(id: "day", date: utcCalendar().startOfDay(for: date), items: items)
    }

    private func thoughtItem(_ id: String, title: String, date: Date, statements: [String]) -> RecentContentItem {
        RecentContentItem(id: id, sourceIDs: [id], date: date, title: title, summary: "",
                          thoughts: statements.enumerated().map {
                              RecentContentThought(claimID: "\(id)-c\($0.offset)", statement: $0.element)
                          },
                          excerpts: [], kind: .material)
    }

    func testFeedbackGroupsShowTaskProgress() {
        struct GroupExpectation {
            let title: String
            let rows: [(id: String, actionID: String, taskTitle: String, relationLabel: String, text: String, available: Bool)]
        }
        struct Case {
            let name: String
            let sources: [SourceRecord]
            let actions: [ActionRecord]
            let dayIDs: [String]
            let groups: [GroupExpectation]
        }
        let calendar = utcCalendar()
        let cases = [
            Case(name: "resolved tasks",
                 sources: [
                    source("f1", createdAt: "2024-05-01T10:00:00Z", transcript: "桌面已经整理完一半",
                           feedbackKind: "reflection", feedbackActionID: "a1", feedbackRelation: "progress"),
                    source("f2", createdAt: "2024-05-01T11:00:00Z", transcript: "又想起要汇报",
                           feedbackKind: "reflection", feedbackActionID: "a2", feedbackRelation: "repeat"),
                 ],
                 actions: [
                    action("a1", claimID: "c1", title: "整理桌面"),
                    action("a2", claimID: "c1", title: "打磨汇报"),
                 ],
                 dayIDs: ["2024-05-01"],
                 groups: [GroupExpectation(title: "任务进展", rows: [
                    ("f2", "a2", "打磨汇报", "再次提及", "又想起要汇报", true),
                    ("f1", "a1", "整理桌面", "实际进展", "桌面已经整理完一半", true),
                 ])]),
            Case(name: "missing tasks and day grouping",
                 sources: [
                    source("f1", createdAt: "2024-05-01T10:00:00Z", transcript: "第一天的反馈",
                           feedbackKind: "reflection", feedbackActionID: "a1", feedbackRelation: "repeat"),
                    source("f2", createdAt: "2024-05-02T10:00:00Z", transcript: "第二天的反馈",
                           feedbackKind: "outcome", feedbackActionID: "gone"),
                 ],
                 actions: [action("a1", claimID: "c1", title: "整理桌面")],
                 dayIDs: ["2024-05-02", "2024-05-01"],
                 groups: [
                    GroupExpectation(title: "任务进展", rows: [
                        ("f2", "gone", "任务已不可用", "实际结果", "第二天的反馈", false),
                    ]),
                    GroupExpectation(title: "任务进展", rows: [
                        ("f1", "a1", "整理桌面", "再次提及", "第一天的反馈", true),
                    ]),
                 ]),
        ]
        for c in cases {
            let snapshot = RecentContentHomeSnapshot.build(sources: c.sources, claims: [], actions: c.actions, calendar: calendar)
            XCTAssertEqual(snapshot.days.map(\.id), c.dayIDs, c.name)
            let feedback = snapshot.days.flatMap(\.items).filter { $0.kind == .feedback }
            XCTAssertEqual(feedback.map(\.title), c.groups.map(\.title), c.name)
            for (item, expected) in zip(feedback, c.groups) {
                let rows = snapshot.progressRows[item.id] ?? []
                XCTAssertEqual(rows.map(\.id), expected.rows.map(\.id), item.id)
                XCTAssertEqual(rows.map(\.actionID), expected.rows.map(\.actionID), item.id)
                XCTAssertEqual(rows.map(\.taskTitle), expected.rows.map(\.taskTitle), item.id)
                XCTAssertEqual(rows.map(\.relationLabel), expected.rows.map(\.relationLabel), item.id)
                XCTAssertEqual(rows.map(\.text), expected.rows.map(\.text), item.id)
                XCTAssertEqual(rows.map(\.isTaskAvailable), expected.rows.map(\.available), item.id)
            }
        }
    }

    func testSnapshotRowsCarryIconStatusAndCount() {
        let sources = [
            source("m1", createdAt: "2024-05-01T10:00:00Z", localOnly: true, jobState: "running"),
            source("m2", createdAt: "2024-05-01T11:00:00Z", jobState: "running"),
            source("f1", createdAt: "2024-05-01T12:00:00Z", transcript: "反馈原话",
                   feedbackKind: "done", feedbackActionID: "a1", feedbackRelation: "progress"),
        ]
        let claims = [
            claim("c1", sourceIDs: ["m1"], statement: "【观点】整理桌面"),
            claim("c2", sourceIDs: ["m2"], statement: "【观点】打磨汇报"),
        ]
        let actions = [action("a1", claimID: "c1", title: "整理桌面")]

        let snapshot = RecentContentHomeSnapshot.build(sources: sources, claims: claims, actions: actions)

        XCTAssertEqual(snapshot.rows["m1"]?.status, .some(.localOnly), "仅本机优先于整理中")
        XCTAssertEqual(snapshot.rows["m2"]?.status, .some(.organizing), "运行中的材料显示整理中")
        XCTAssertEqual(snapshot.rows["m2"]?.icon, "doc.text", "文字材料显示文档图标")
        guard let feedback = snapshot.days.flatMap(\.items).first(where: { $0.kind == .feedback }) else {
            return XCTFail("应有一组任务进展")
        }
        XCTAssertEqual(snapshot.rows[feedback.id]?.icon, "arrow.triangle.2.circlepath", "反馈行显示循环图标")
        XCTAssertEqual(snapshot.rows[feedback.id]?.count, snapshot.progressRows[feedback.id]?.count, "反馈行计数来自快照")
    }

    func testDigestTasksFilterAndKeepActionOrder() {
        struct Case {
            let name: String
            let claims: [CandidateClaim]
            let actions: [ActionRecord]
            let reviewRequired: Set<String>
            let expected: [String]
        }
        let s1 = source("s1", createdAt: "2024-05-01T10:00:00Z")
        let cases = [
            Case(name: "task order across claims",
                 claims: [
                    claim("c1", sourceIDs: ["s1"], statement: "【观点】第一件事"),
                    claim("c2", sourceIDs: ["s1"], statement: "【观点】第二件事"),
                 ],
                 actions: [
                    action("a1", claimID: "c2", title: "第二组第一件"),
                    action("a2", claimID: "c1", title: "第一组第一件"),
                    action("a3", claimID: "c2", title: "第二组第二件"),
                    action("a4", claimID: "c1", title: "不是任务", kind: "note"),
                    action("a5", claimID: "c1", title: "已完成的事", state: "done"),
                 ],
                 reviewRequired: [],
                 expected: ["a1", "a2", "a3"]),
            Case(name: "review required excluded",
                 claims: [claim("c1", sourceIDs: ["s1"], statement: "【观点】整理桌面")],
                 actions: [
                    action("a1", claimID: "c1", title: "整理桌面"),
                    action("a2", claimID: "c1", title: "待核对的行动"),
                 ],
                 reviewRequired: ["a2"],
                 expected: ["a1"]),
            Case(name: "all need review",
                 claims: [claim("c1", sourceIDs: ["s1"], statement: "【观点】整理桌面")],
                 actions: [action("a1", claimID: "c1", title: "待核对的行动")],
                 reviewRequired: ["a1"],
                 expected: []),
        ]
        for c in cases {
            let snapshot = RecentContentHomeSnapshot.build(sources: [s1], claims: c.claims, actions: c.actions,
                                                           reviewRequiredActionIDs: c.reviewRequired)
            XCTAssertEqual(snapshot.digests["s1"]?.tasks.map(\.id), c.expected, c.name)
        }
    }
}
