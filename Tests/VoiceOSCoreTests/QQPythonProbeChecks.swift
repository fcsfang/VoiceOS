import XCTest
@testable import VoiceOSPlatform

final class QQPythonProbeChecks: XCTestCase {
    func testProbeClassifiesInjectedProcessOutput() {
        XCTAssertEqual(QQMonitorHelper.classifyPythonProbe(exitCode: 0, stderr: ""), .available)
        XCTAssertEqual(QQMonitorHelper.classifyPythonProbe(
            exitCode: 1, stderr: "ModuleNotFoundError: No module named 'qqnt_export_macos'"), .missingPackage)
        XCTAssertEqual(QQMonitorHelper.classifyPythonProbe(
            exitCode: 2, stderr: "PermissionError: Operation not permitted"), .cannotRun)
        XCTAssertEqual(QQMonitorHelper.classifyPythonProbe(exitCode: nil, stderr: "launch failed"), .cannotRun)
    }
}
