// Read-only capability probe. No permission prompts, recording, reminders fetch,
// model downloads, or API requests. This is not application code.
import Foundation
import EventKit
import AVFoundation
import Speech

@main
struct PlatformCapabilities {
    static func main() async throws {
        var result: [String: Any] = [
            "probe": "platform-capabilities-v1",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "reminders_authorization_raw": EKEventStore.authorizationStatus(for: .reminder).rawValue,
            "microphone_authorization_raw": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "legacy_speech_authorization_raw": SFSpeechRecognizer.authorizationStatus().rawValue,
            "permission_requested": false,
            "personal_data_read": false,
            "external_write": false,
            "transcription_executed": false
        ]
        if #available(macOS 26.0, *) {
            result["speech_transcriber_available"] = SpeechTranscriber.isAvailable
            result["speech_transcriber_supported_locales"] = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
            result["speech_transcriber_installed_locales"] = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        } else {
            result["speech_transcriber_available"] = false
            result["speech_transcriber_unavailable_reason"] = "requires macOS 26 or later"
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
