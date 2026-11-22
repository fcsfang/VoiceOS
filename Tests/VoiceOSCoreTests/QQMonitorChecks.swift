import XCTest
@testable import VoiceOSCore
@testable import VoiceOSPlatform

final class QQMonitorChecks: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var script: URL { repoRoot.appendingPathComponent("scripts/qqmonitor/qq_read_range.py") }

    func testFixturePayloadDecodesIntoContract() throws {
        let fixture = """
        {"version":1,"conversation_id":"group:fixture","conversation_name":"示例班级群","range":{"start":"2026-11-17T09:00:00+08:00","end":"2026-11-18T09:00:00+08:00"},"message_count":4,"messages":[{"message_id":"9001","timestamp_ms":1763424000000,"sender_name":"示例同学","sender_id":"u_fixture","type":"text","text":"学院通知：奖学金申请截止 11 月 20 日","meta":{}},{"message_id":"9002","timestamp_ms":1763424060000,"sender_name":"示例同学","sender_id":"u_fixture","type":"image","text":"[图片：通知截图]","meta":{"chatlab_type":1}},{"message_id":"9003","timestamp_ms":1763424120000,"sender_name":"示例同学","sender_id":"u_fixture","type":"forward","text":"[合并转发：奖学金材料清单]","meta":{"chatlab_type":26}},{"message_id":"9004","timestamp_ms":1763424180000,"sender_name":"示例同学","sender_id":"u_fixture","type":"other","text":"[语音 5 秒]","meta":{"chatlab_type":2}}],"truncated":false}
        """
        let result = try QQMonitorHelper.decodeResult(Data(fixture.utf8))
        XCTAssertEqual(result.conversationID, "group:fixture")
        XCTAssertEqual(result.conversationName, "示例班级群")
        XCTAssertEqual(result.messages.count, 4)
        XCTAssertEqual(result.messages.map(\.externalID), ["9001", "9002", "9003", "9004"])
        XCTAssertEqual(result.messages[0].kind, .text)
        XCTAssertEqual(result.messages[1].kind, .image)
        XCTAssertEqual(result.messages[1].content, "[图片：通知截图]", "图片消息保留待查看占位")
        XCTAssertEqual(result.messages[2].kind, .forward, "合并转发消息保留待查看类型")
        XCTAssertEqual(result.messages[2].content, "[合并转发：奖学金材料清单]", "合并转发消息占位应可读")
        XCTAssertEqual(result.messages[3].kind, .other, "语音等未细化类型归入 other")
        XCTAssertEqual(result.messages[3].content, "[语音 5 秒]", "语音消息占位应可读")
        XCTAssertNotNil(result.messages[0].sentAt)
        XCTAssertFalse(result.truncated)
    }

    func testInvalidPayloadIsRejectedInChinese() {
        XCTAssertThrowsError(try QQMonitorHelper.decodeResult(Data("{}".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("QQ 读取结果"),
                          "无效读取结果应给出中文诊断：\(error.localizedDescription)")
        }
    }

    func testContractErrorsClassifyPermissionAndKeyIssues() {
        let cases: [(name: String, stderr: String, mustContain: [String], mustNotContain: [String])] = [
            ("permission_denied 归为权限问题",
             #"{"version":1,"error":{"code":"permission_denied","zh":"需要完全磁盘访问权限","en":"PermissionError: [Errno 1] Operation not permitted: /Users/example/Library/Containers/com.tencent.qq/nt_db/nt_msg.db"}}"#,
             ["permission_denied", "完全磁盘访问权限", "系统设置"],
             ["重新导出密钥"]),
            ("旧脚本把权限问题报成密钥错误",
             #"{"version":1,"error":{"code":"key_invalid","zh":"密钥或 QQ 数据无法读取","en":"PermissionError: [Errno 1] Operation not permitted: /Users/example/nt_msg.db"}}"#,
             ["完全磁盘访问权限"],
             []),
            ("真正的密钥问题保留密钥指引",
             #"{"version":1,"error":{"code":"key_invalid","zh":"密钥文件缺失或为空","en":"key file unavailable: /tmp/qq-key.bin"}}"#,
             ["重新导出密钥"],
             ["完全磁盘访问权限"]),
            ("密钥轮换说明 QQ 升级",
             #"{"version":1,"error":{"code":"key_invalid","zh":"QQ 可能已升级导致密钥失效，请重新导出密钥","en":"RuntimeError: expected exactly one valid key candidate; found 0"}}"#,
             ["QQ 可能已升级", "重新导出密钥"],
             ["完全磁盘访问权限"]),
        ]
        for c in cases {
            let message = QQMonitorHelper.contractError(stderr: Data(c.stderr.utf8)).localizedDescription
            for expected in c.mustContain {
                XCTAssertTrue(message.contains(expected), "\(c.name)：应包含 \(expected)：\(message)")
            }
            for unexpected in c.mustNotContain {
                XCTAssertFalse(message.contains(unexpected), "\(c.name)：不应包含 \(unexpected)：\(message)")
            }
        }

        let probe = QQMonitorHelper.mirrorProbeItem(exitCode: 1,
                                                    stderr: "RuntimeError: expected exactly one valid key candidate; found 0")
        XCTAssertFalse(probe.ok, "检查 QQ 依赖不应把密钥轮换报告为全绿")
        XCTAssertTrue(probe.detail.contains("重新导出密钥"), "镜像库探测应给出密钥修复指引：\(probe.detail)")
    }

    func testPermissionRecheckClassifiesAsFullDiskAccessIssue() {
        let denied = QQMonitorHelper.directoryProbeItem(
            exitCode: 1, stdout: "",
            stderr: "PermissionError: [Errno 1] Operation not permitted: '/Users/example/Library/Containers/com.tencent.qq'",
            account: "10001")
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(denied.needsFullDiskAccess, "目录枚举复核为权限问题时应提示完全磁盘访问权限")
        XCTAssertTrue(denied.detail.contains("完全磁盘访问权限"), "应给出 m62 的权限指引：\(denied.detail)")
        let missing = QQMonitorHelper.directoryProbeItem(
            exitCode: 1, stdout: "",
            stderr: "FileNotFoundError: no QQNT account message databases found", account: nil)
        XCTAssertFalse(missing.ok)
        XCTAssertFalse(missing.needsFullDiskAccess, "真正的数据目录缺失不应误报为权限问题")
        XCTAssertTrue(missing.detail.contains("登录"), "数据目录缺失应提示确认登录：\(missing.detail)")
    }

    func testScriptPassesStaticCompileCheck() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "系统 Python 不可用，跳过脚本静态检查")
        let compiled = FileManager.default.temporaryDirectory.appendingPathComponent("qqmonitor-" + UUID().uuidString + ".pyc")
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-c",
                             "import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)",
                             script.path, compiled.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "qq_read_range.py 应通过静态编译检查：\(detail)")
        try? FileManager.default.removeItem(at: compiled)
    }

    func testScriptEmitsStructuredErrorContract() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "系统 Python 不可用，跳过脚本错误契约检查")
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let request = #"{"version":1,"key_path":"/nonexistent/key.bin","cache_dir":"/tmp/qqmonitor-fixture-cache","conversation_id":"group:fixture","start_iso8601":"2026-11-17T00:00:00+08:00","end_iso8601":"2026-11-18T00:00:00+08:00"}"#
        input.fileHandleForWriting.write(Data(request.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0, "读取失败应以非零退出码结束")
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init),
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            XCTFail("stderr 应以一行 JSON 说明失败原因：\(stderr)")
            return
        }
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(error["code"] as? String)
        XCTAssertNotNil(error["zh"] as? String, "诊断应包含中文原因")
        XCTAssertNotNil(error["en"] as? String, "诊断应包含英文原因")
        XCTAssertFalse(stderr.contains("key.bin\":\"") && stderr.contains("secret"), "诊断不得回显密钥内容")
    }
}