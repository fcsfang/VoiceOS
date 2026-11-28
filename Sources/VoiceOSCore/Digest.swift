import Foundation
import CryptoKit

/// Hex-encoded SHA-256 is the one digest format used for identities,
/// fingerprints and receipts across the app, tools and asset checks.
public enum Digest {
    public static func sha256(_ data: Data) -> String {
        hex(of: SHA256.hash(data: data))
    }

    public static func hex<S: Sequence>(of bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
