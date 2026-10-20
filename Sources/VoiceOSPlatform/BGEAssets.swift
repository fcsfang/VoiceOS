import Foundation
import CryptoKit
import VoiceOSCore

struct BGEAssets {
    struct Manifest: Decodable {
        struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
        let format: String
        let model: String
        let revision: String
        let precision: String
        let dimension: Int
        let max_tokens: Int
        let window_scalars: Int
        let overlap_scalars: Int
        let source_sha256: [String:String]
        let files: [File]
    }
    let root: URL
    let manifest: Manifest
    init(root: URL) throws {
        self.root = root
        let raw = try Data(contentsOf:root.appendingPathComponent("manifest.json"))
        guard raw.count <= 65536 else { throw VoiceOSError("本地模型清单过大") }
        manifest = try JSONDecoder().decode(Manifest.self,from:raw)
        guard manifest.format == "voiceos-bge-coreml-v1", manifest.model == "BAAI/bge-small-zh-v1.5",
              manifest.revision == "7999e1d3359715c523056ef9478215996d62a620", manifest.precision == "float32",
              manifest.dimension == 512, manifest.max_tokens == 512, manifest.window_scalars == 256, manifest.overlap_scalars == 96,
              manifest.source_sha256["model.safetensors"] == "354763b9b1357bc9c44f62c6be2276321081ed2567773608c0d0785b61d5a026",
              manifest.source_sha256["vocab.txt"] == "45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c",
              !manifest.files.isEmpty, manifest.files.count <= 100,
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw VoiceOSError("本地模型版本或配置不符") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for file in manifest.files {
            let parts = file.path.split(separator:"/",omittingEmptySubsequences:false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  file.path == "vocab.txt" || parts.first == "Encoder.mlmodelc",
                  (0...200_000_000).contains(file.bytes) else { throw VoiceOSError("本地模型文件清单不符") }
            let url = root.appendingPathComponent(file.path)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
                  try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw VoiceOSError("本地模型文件路径不符") }
            let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
            guard bytes.count == file.bytes, Self.hash(bytes) == file.sha256 else { throw VoiceOSError("本地模型文件完整性检查失败") }
        }
        guard manifest.files.contains(where:{ $0.path == "vocab.txt" && $0.sha256 == manifest.source_sha256["vocab.txt"] }),
              manifest.files.contains(where:{ $0.path.hasPrefix("Encoder.mlmodelc/") }) else { throw VoiceOSError("本地模型文件缺失") }
        // Every consumed compiled file must be covered; no unsigned extra projection.
        let folder = root.appendingPathComponent("Encoder.mlmodelc")
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw VoiceOSError("本地模型目录不允许链接") }
        guard let enumerator = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw VoiceOSError("本地模型目录不可用") }
        var actual: Set<String> = []
        for case let url as URL in enumerator {
            let info = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw VoiceOSError("本地模型目录不允许链接") }
            if info.isRegularFile == true { actual.insert("Encoder.mlmodelc/" + String(url.path.dropFirst(folder.path.count + 1))) }
        }
        guard actual == Set(manifest.files.filter { $0.path.hasPrefix("Encoder.mlmodelc/") }.map(\.path)) else { throw VoiceOSError("本地模型清单与目录不一致") }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}
