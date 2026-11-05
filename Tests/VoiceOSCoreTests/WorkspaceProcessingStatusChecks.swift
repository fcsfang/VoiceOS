import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

extension CoreFlowTests {
    func testRunningOperationShowsItsOwnLabel() {
        let status = WorkspaceProcessingStatus(knowledgeReview: .running)
        XCTAssertEqual(status.title, "正在核查知识理解")
        XCTAssertTrue(status.isRunning)
    }

    func testNoRunningOperationShowsStableFallback() {
        let status = WorkspaceProcessingStatus()
        XCTAssertEqual(status.title, WorkspaceProcessingStatus.idleTitle)
        XCTAssertFalse(status.isRunning)
    }

    func testCompletedOperationNeverShowsBusyLabel() {
        let status = WorkspaceProcessingStatus(
            knowledgeReview: .completed,
            assistantExecution: .completed,
            followup: .completed,
            topicOrganization: .completed)
        XCTAssertEqual(status.title, WorkspaceProcessingStatus.idleTitle)
        XCTAssertFalse(status.isRunning)
    }

    func testRunningAssistantExecutionShowsItsLabel() {
        let status = WorkspaceProcessingStatus(assistantExecution: .running)
        XCTAssertEqual(status.title, "AI 正在执行代办")
    }

    func testForegroundActivityOutranksBackgroundWork() {
        let status = WorkspaceProcessingStatus(activityLabel: "正在本地转写", knowledgeReview: .running)
        XCTAssertEqual(status.title, "正在本地转写")
    }
}
