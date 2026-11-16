import XCTest
@testable import VoiceOSCore

final class ActionRowStatusChecks: XCTestCase {
    private func facts(_ configure: (inout ActionRowFacts) -> Void) -> ActionRowStatus {
        var facts = ActionRowFacts()
        configure(&facts)
        return ActionRowLayout.status(facts)
    }

    private func action(id: String, parent: String?, state: String) -> ActionRecord {
        ActionRecord(id: id, claimID: "claim", claimReviewVersion: 1, title: "t", kind: "task",
                     intentActor: "user", note: "", state: state, validity: "current", version: 1,
                     autoSend: false, intent: nil, commandID: "c", createdAt: "", parentID: parent)
    }

    func testMetaCarriesDueInsteadOfSource() {
        let row = facts { facts in
            facts.isGoal = true
            facts.due = "到期 11月20日"
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.meta, "到期 11月20日")
        XCTAssertFalse(row.meta.contains("来自"))
    }

    func testMetaFallsBackToSourceWhenNoDue() {
        let row = facts { facts in
            facts.isGoal = true
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.meta, "来自『早餐时的想法』")
    }

    func testGoalShowsOpenNextStepCountInStatusSlot() {
        let row = facts { facts in
            facts.isGoal = true
            facts.nextStepCount = 2
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.status, "2 个下一步")
        XCTAssertEqual(row.tone, .secondary)
        XCTAssertFalse(row.meta.contains("下一步"))
    }

    func testGoalWithNoNextStepsLeavesStatusToTheBanner() {
        let row = facts { facts in
            facts.isGoal = true
            facts.nextStepCount = 0
        }
        XCTAssertEqual(row.status, "")
    }

    func testNeedsReviewGroupDoesNotReafirmItsOwnStatus() {
        let row = facts { facts in
            facts.group = .needsReview
            facts.requiresReview = true
        }
        XCTAssertEqual(row.status, "")
    }

    func testNeedsReviewShowsAsWarningOutsideItsGroup() {
        let row = facts { facts in
            facts.requiresReview = true
        }
        XCTAssertEqual(row.status, "待核对")
        XCTAssertEqual(row.tone, .warning)
    }

    func testCompletedGroupDoesNotRepeatCompletion() {
        let row = facts { facts in
            facts.group = .completed
            facts.state = "completed"
        }
        XCTAssertEqual(row.status, "")
    }

    func testHistoricalRowDoesNotRepeatTheGroupLabel() {
        let row = facts { facts in
            facts.group = .history
            facts.validity = "frozen"
        }
        XCTAssertEqual(row.status, "")
    }

    func testDismissedRowKeepsItsOwnOutcome() {
        let row = facts { facts in
            facts.group = .history
            facts.state = "dismissed"
        }
        XCTAssertEqual(row.status, "已放下")
        XCTAssertEqual(row.tone, .tertiary)
    }

    func testWarningExceptionWinsOverNextStepCount() {
        let row = facts { facts in
            facts.isGoal = true
            facts.nextStepCount = 3
            facts.localUnsynced = true
        }
        XCTAssertEqual(row.status, "本地未同步")
        XCTAssertEqual(row.tone, .warning)
    }

    func testNextStepCountsCountOpenChildrenPerOutcome() {
        let actions = [
            action(id: "a", parent: "goal", state: "open"),
            action(id: "b", parent: "goal", state: "completed"),
            action(id: "c", parent: "goal", state: "open"),
            action(id: "d", parent: nil, state: "open"),
            action(id: "e", parent: "other", state: "open"),
        ]
        XCTAssertEqual(ActionRowLayout.nextStepCounts(actions), ["goal": 2, "other": 1])
    }
}
