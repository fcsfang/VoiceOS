import XCTest
import VoiceOSCore
import VoiceOSPlatform

final class LocalQwenSpeechPortTests: XCTestCase {
    func testRestartRestoresQwenSnapshotWithoutReadingOriginalConfigFile() throws {
        let runner=root.appendingPathComponent("runner.py")
        try Data().write(to:runner)
        let config=try JSONSerialization.data(withJSONObject:["format":"voiceos-local-qwen-v1","python":"/bin/sh","runner":runner.path,"model":root.path])
        let original=root.appendingPathComponent("selected-config.json")
        try config.write(to:original)
        let saved=try JSONEncoder().encode(LocalSpeechSelection(configuration:config))
        try FileManager.default.removeItem(at:original)
        let restored=try JSONDecoder().decode(LocalSpeechSelection.self,from:saved)
        XCTAssertEqual(restored.backend,.qwen)
        XCTAssertTrue(try restored.port().backendIdentity.hasPrefix("Qwen3-ASR"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try restored.port())
        XCTAssertEqual(restored.backend,.qwen)
    }
    func testDefaultQwenRequiresConfigurationAndAppleNeedsExplicitSelection() throws {
        XCTAssertThrowsError(try LocalSpeechSelection().port())
        XCTAssertEqual(try LocalSpeechSelection(backend:.apple).port().backendIdentity,"Apple SpeechAnalyzer")
        XCTAssertThrowsError(try LocalSpeechSelection(backend:.apple,configuration:Data()).port())
    }
    var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("qwen-port-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data().write(to:root.appendingPathComponent("model.safetensors"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func port(script: String) throws -> LocalQwenSpeechPort {
        let runner=root.appendingPathComponent("fixture.sh")
        try Data(script.utf8).write(to:runner)
        return try LocalQwenSpeechPort(python:URL(fileURLWithPath:"/bin/sh"),runner:runner,model:root)
    }
    func testProcessFailureDoesNotFallBackOrReturnTranscript() async throws {
        let port=try port(script:"exit 3\n")
        do { _=try await port.transcribe(root.appendingPathComponent("not-used.wav"),locale:"zh_CN");XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("不自动切换")) }
    }
    func testForeignBackendReceiptIsRejected() async throws {
        let port=try port(script:"cat > \"$6\" <<'JSON'\n{\"backend\":\"foreign\",\"text\":\"\",\"spans\":[],\"audio_uploaded\":false}\nJSON\n")
        do { _=try await port.transcribe(root.appendingPathComponent("not-used.wav"),locale:"zh_CN");XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("身份无效")) }
    }
    func testCancellationTerminatesRunningWorker() async throws {
        let marker=root.appendingPathComponent("launched")
        let port=try port(script:"touch '"+marker.path+"'\nexec /bin/sleep 30\n")
        let task=Task { () throws -> SpeechText in
            return try await port.transcribe(root.appendingPathComponent("not-used.wav"),locale:"zh_CN")
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath:marker.path) { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        let start=Date()
        task.cancel()
        do { _=try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
    }
}
