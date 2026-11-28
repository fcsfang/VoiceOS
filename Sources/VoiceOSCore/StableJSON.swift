import Foundation

/// Deterministic JSON for bytes that feed identities, digests or persisted
/// receipts. One place decides the encoder configuration.
public enum StableJSON {
    public static func makeEncoder(dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let dateEncodingStrategy { encoder.dateEncodingStrategy = dateEncodingStrategy }
        return encoder
    }
}
