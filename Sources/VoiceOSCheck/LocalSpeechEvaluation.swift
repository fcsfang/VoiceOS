import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Private local output only; no library, text model or external action.
func runLocalSpeechEvaluation(_ args: [String]) async throws {
    guard args.count == 3 else { throw VoiceOSError("speech-eval requires runtime audio and new runtime output JSON") }
    let allowed = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").resolvingSymlinksInPath().path + "/"
    let audio = URL(fileURLWithPath:args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath:args[2]).standardizedFileURL.resolvingSymlinksInPath()
    guard audio.path.hasPrefix(allowed), output.path.hasPrefix(allowed),
          !FileManager.default.fileExists(atPath:output.path) else { throw VoiceOSError("Local evaluation requires runtime paths and cannot overwrite results") }
    let media = try await NativeMediaInspector().inspect(audio)
    let speech = NativeSpeechPort(), start = Date()
    let result = try await speech.transcribe(audio,locale:"zh_CN")
    try result.validate(duration:media.duration)
    let seconds = Date().timeIntervalSince(start)
    let report: [String:Any] = ["backend":speech.backendIdentity,"elapsed_seconds":seconds,
        "duration_seconds":media.duration,"text":result.text,
        "spans":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.spans)),"audio_uploaded":false]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.withoutOverwriting)
    print("Local evaluation: \(result.text.unicodeScalars.count) scalars, \(seconds) seconds; audio uploaded=false")
}
