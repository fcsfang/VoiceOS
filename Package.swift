// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "VoiceOS", platforms: [.macOS("26.0")],
    products: [.library(name: "VoiceOSCore", targets: ["VoiceOSCore"]), .executable(name: "VoiceOS", targets: ["VoiceOSApp"]), .executable(name: "voiceos-check", targets: ["VoiceOSCheck"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "VoiceOSCore", dependencies: ["CSQLite"]),
        .target(name: "VoiceOSPlatform", dependencies: ["VoiceOSCore"]),
        .executableTarget(name: "VoiceOSApp", dependencies: ["VoiceOSCore", "VoiceOSPlatform"]),
        .executableTarget(name: "VoiceOSCheck", dependencies: ["VoiceOSCore", "VoiceOSPlatform"]),
        .testTarget(name: "VoiceOSCoreTests", dependencies: ["VoiceOSCore"])
    ])
